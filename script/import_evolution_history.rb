require 'base64'
require 'stringio'
require 'tempfile'
require 'json'
require 'net/http'
require 'set'
require 'uri'

class EvolutionHistoryImporter
  DEFAULT_PAGE_SIZE = 100
  DEFAULT_MEDIA_MAX_BYTES = 25 * 1024 * 1024

  def initialize
    @evolution_base_url = sanitize_url!(ENV.fetch('EVOLUTION_API_BASE_URL'))
    @evolution_api_key = ENV.fetch('EVOLUTION_API_KEY')
    @instance_name = ENV.fetch('EVOLUTION_INSTANCE')
    @account_id = ENV.fetch('CHATWOOT_ACCOUNT_ID', '1').to_i
    @page_size = ENV.fetch('EVOLUTION_PAGE_SIZE', DEFAULT_PAGE_SIZE).to_i
    @target_remote_jid = ENV['EVOLUTION_REMOTE_JID'].presence
    @resolve_imported_conversations = ActiveModel::Type::Boolean.new.cast(
      ENV.fetch('CHATWOOT_RESOLVE_IMPORTED_CONVERSATIONS', 'true')
    )
    @media_max_bytes = ENV.fetch('EVOLUTION_MEDIA_MAX_BYTES', DEFAULT_MEDIA_MAX_BYTES).to_i
    @imported_count = 0
    @skipped_count = 0
    @processed_canonical_jids = Set.new
  end

  def perform
    @account = Account.find(@account_id)
    @chatwoot_config = get_json("/chatwoot/find/#{@instance_name}")
    @inbox = resolve_inbox!

    puts "Evolution instance: #{@instance_name}"
    puts "Chatwoot account: #{@account.id}"
    puts "Chatwoot inbox: #{@inbox.id} (#{@inbox.name})"

    chats = fetch_chats
    puts "Chats found in Evolution: #{chats.size}"

    chats.each_with_index do |chat, index|
      evolution_remote_jid = chat['remoteJid']
      canonical_remote_jid = canonical_remote_jid(chat)
      next if evolution_remote_jid.blank?
      next if canonical_remote_jid.blank?

      if @target_remote_jid.present? && evolution_remote_jid != @target_remote_jid && canonical_remote_jid != @target_remote_jid
        next
      end

      next if @processed_canonical_jids.include?(canonical_remote_jid)
      @processed_canonical_jids << canonical_remote_jid

      import_chat(chat, evolution_remote_jid, canonical_remote_jid, index + 1, chats.size)
    end

    puts "Import finished. Imported messages: #{@imported_count}, skipped duplicates: #{@skipped_count}"
  end

  private

  def resolve_inbox!
    inbox_id = ENV['CHATWOOT_INBOX_ID'].presence
    return @account.inboxes.find(inbox_id) if inbox_id

    inbox_name = ENV['CHATWOOT_INBOX_NAME'].presence || @chatwoot_config['nameInbox'].presence
    raise 'CHATWOOT_INBOX_ID or CHATWOOT_INBOX_NAME is required' if inbox_name.blank?

    @account.inboxes.find_by!(name: inbox_name)
  end

  def fetch_chats
    response = post_json("/chat/findChats/#{@instance_name}")
    raise "Unexpected chat list response: #{response.class}" unless response.is_a?(Array)

    response
  end

  def import_chat(chat, evolution_remote_jid, canonical_remote_jid, index, total)
    records = fetch_all_messages(evolution_remote_jid)

    if records.empty?
      puts "[#{index}/#{total}] #{evolution_remote_jid}: no messages to import"
      return
    end

    records.sort_by! { |record| message_timestamp(record) || Time.at(0) }

    contact_inbox = build_contact_inbox(chat, canonical_remote_jid)
    conversation = find_or_create_conversation(contact_inbox, canonical_remote_jid, records)
    existing_source_ids = conversation.messages.where(source_id: records.map { |record| source_id_for(record) }).pluck(:source_id).to_set

    rows = []
    media_records = []

    records.each do |record|
      source_id = source_id_for(record)
      next if source_id.blank?

      if existing_source_ids.include?(source_id)
        @skipped_count += 1
        next
      end

      timestamp = message_timestamp(record) || Time.current
      from_me = record.dig('key', 'fromMe') == true
      content = message_content(record)

      if media_record?(record)
        media_records << { record: record, source_id: source_id, timestamp: timestamp, from_me: from_me, content: content }
        next
      end

      rows << message_row(
        content: content,
        conversation_id: conversation.id,
        contact_id: contact_inbox.contact_id,
        from_me: from_me,
        source_id: source_id,
        timestamp: timestamp,
        canonical_remote_jid: canonical_remote_jid,
        evolution_remote_jid: evolution_remote_jid,
        message_type: record['messageType']
      )
    end

    if rows.any?
      Message.insert_all!(rows)
      @imported_count += rows.size
    end

    media_records.each do |data|
      import_media_message!(conversation, contact_inbox, data, canonical_remote_jid, evolution_remote_jid)
    end

    sync_conversation_metadata!(conversation, contact_inbox.contact, records)

    puts "[#{index}/#{total}] #{evolution_remote_jid} => #{canonical_remote_jid}: imported #{rows.size + media_records.size}/#{records.size}"
  end

  def build_contact_inbox(chat, canonical_remote_jid)
    existing = @inbox.contact_inboxes.find_by(source_id: canonical_remote_jid)
    return existing if existing.present?

    contact_attributes = {
      name: sanitize_text(chat['pushName']) || fallback_name(canonical_remote_jid),
      identifier: canonical_remote_jid
    }

    phone_number = phone_number_for(chat, canonical_remote_jid)
    contact_attributes[:phone_number] = phone_number if phone_number.present?

    ContactInboxWithContactBuilder.new(
      inbox: @inbox,
      source_id: canonical_remote_jid,
      contact_attributes: contact_attributes
    ).perform
  end

  def find_or_create_conversation(contact_inbox, canonical_remote_jid, records)
    conversation = Conversation.where(account_id: @account.id, inbox_id: @inbox.id)
                               .where("additional_attributes ->> 'remote_jid' = ?", canonical_remote_jid)
                               .order(created_at: :asc)
                               .first
    return conversation if conversation.present?

    conversation = contact_inbox.conversations.order(created_at: :asc).first
    return conversation if conversation

    latest_message = records.max_by { |record| message_timestamp(record) || Time.at(0) }
    latest_timestamp = message_timestamp(latest_message) || Time.current
    latest_from_me = latest_message.dig('key', 'fromMe') == true

    Conversation.create!(
      account_id: @account.id,
      inbox_id: @inbox.id,
      contact_id: contact_inbox.contact_id,
      contact_inbox_id: contact_inbox.id,
      status: @resolve_imported_conversations ? :resolved : (latest_from_me ? :resolved : :open),
      additional_attributes: {
        imported_from: 'evolution',
        remote_jid: canonical_remote_jid,
        evolution_instance: @instance_name
      },
      created_at: records.first ? (message_timestamp(records.first) || latest_timestamp) : latest_timestamp,
      updated_at: latest_timestamp,
      last_activity_at: latest_timestamp,
      waiting_since: @resolve_imported_conversations ? nil : (latest_from_me ? nil : latest_timestamp)
    )
  end

  def sync_conversation_metadata!(conversation, contact, records)
    latest = records.max_by { |record| message_timestamp(record) || Time.at(0) }
    earliest = records.min_by { |record| message_timestamp(record) || Time.at(0) }
    latest_timestamp = message_timestamp(latest) || Time.current
    earliest_timestamp = message_timestamp(earliest) || latest_timestamp
    first_reply = records.select { |record| record.dig('key', 'fromMe') == true }
                         .map { |record| message_timestamp(record) }
                         .compact
                         .min

    latest_from_me = latest&.dig('key', 'fromMe') == true

    conversation.update_columns(
      created_at: [conversation.created_at, earliest_timestamp].compact.min,
      updated_at: Time.current,
      last_activity_at: latest_timestamp,
      status: @resolve_imported_conversations ? Conversation.statuses[:resolved] : (latest_from_me ? Conversation.statuses[:resolved] : Conversation.statuses[:open]),
      waiting_since: @resolve_imported_conversations ? nil : (latest_from_me ? nil : latest_timestamp),
      first_reply_created_at: conversation.first_reply_created_at || first_reply
    )

    contact.update_columns(last_activity_at: [contact.last_activity_at, latest_timestamp].compact.max)
  end

  def fetch_all_messages(remote_jid)
    page = 1
    all_records = []
    previous_first_id = nil

    loop do
      response = post_json(
        "/chat/findMessages/#{@instance_name}",
        {
          where: { key: { remoteJid: remote_jid } },
          page: page,
          limit: @page_size
        }
      )

      message_payload = response['messages'] || {}
      records = message_payload['records'] || []
      current_page = message_payload['currentPage'].to_i
      total_pages = [message_payload['pages'].to_i, 1].max
      first_id = records.first&.dig('id')

      all_records.concat(records)

      break if records.empty?
      break if current_page >= total_pages
      break if previous_first_id == first_id

      previous_first_id = first_id
      page += 1
    end

    all_records
  end

  def message_row(content:, conversation_id:, contact_id:, from_me:, source_id:, timestamp:, canonical_remote_jid:, evolution_remote_jid:, message_type:)
    {
      content: content,
      account_id: @account.id,
      inbox_id: @inbox.id,
      conversation_id: conversation_id,
      message_type: from_me ? Message.message_types[:outgoing] : Message.message_types[:incoming],
      private: false,
      sender_type: from_me ? nil : 'Contact',
      sender_id: from_me ? nil : contact_id,
      status: from_me ? Message.statuses[:delivered] : Message.statuses[:sent],
      source_id: source_id,
      content_type: Message.content_types[:text],
      content_attributes: {
        external_created_at: timestamp,
        imported_from: 'evolution'
      },
      additional_attributes: {
        imported_from: 'evolution',
        remote_jid: canonical_remote_jid,
        evolution_remote_jid: evolution_remote_jid,
        evolution_message_type: message_type
      },
      processed_message_content: content&.truncate(150_000),
      created_at: timestamp,
      updated_at: timestamp
    }
  end

  def import_media_message!(conversation, contact_inbox, data, canonical_remote_jid, evolution_remote_jid)
    record = data.fetch(:record)
    source_id = data.fetch(:source_id)
    timestamp = data.fetch(:timestamp)
    from_me = data.fetch(:from_me)
    content = data.fetch(:content)

    message = Message.create!(
      content: content,
      account_id: @account.id,
      inbox_id: @inbox.id,
      conversation_id: conversation.id,
      message_type: from_me ? :outgoing : :incoming,
      private: false,
      sender_type: from_me ? nil : 'Contact',
      sender_id: from_me ? nil : contact_inbox.contact_id,
      status: from_me ? :delivered : :sent,
      source_id: source_id,
      content_type: :text,
      content_attributes: {
        external_created_at: timestamp,
        imported_from: 'evolution'
      },
      additional_attributes: {
        imported_from: 'evolution',
        remote_jid: canonical_remote_jid,
        evolution_remote_jid: evolution_remote_jid,
        evolution_message_type: record['messageType']
      },
      processed_message_content: content&.truncate(150_000),
      created_at: timestamp,
      updated_at: timestamp
    )

    attachment_payload = evolution_media_payload(record)
    if attachment_payload.present?
      attach_media!(message, record, attachment_payload)
    end

    @imported_count += 1
  rescue StandardError => e
    @skipped_count += 1
    puts "#{canonical_remote_jid} #{source_id}: media import failed: #{e.class} #{e.message}"
  end

  def source_id_for(record)
    sanitize_text(record.dig('key', 'id') || record['id'])
  end

  def message_timestamp(record)
    raw = record['messageTimestamp']
    return if raw.blank?

    Time.zone.at(raw.to_i)
  rescue StandardError
    nil
  end

  def media_record?(record)
    message = record['message'] || {}
    return true if message['imageMessage'].present?
    return true if message['videoMessage'].present?
    return true if message['documentMessage'].present?
    return true if message['audioMessage'].present?
    return true if message['stickerMessage'].present?

    %w[imageMessage videoMessage documentMessage audioMessage stickerMessage].include?(record['messageType'])
  end

  def evolution_media_payload(record)
    key_id = record.dig('key', 'id')
    return if key_id.blank?

    convert_to_mp4 = record['messageType'] == 'videoMessage'
    response = post_json(
      "/chat/getBase64FromMediaMessage/#{@instance_name}",
      { message: { key: { id: key_id } }, convertToMp4: convert_to_mp4 }
    )

    parse_evolution_media_response(response, record)
  end

  def parse_evolution_media_response(response, record)
    if response.is_a?(String)
      return if response.strip.blank?

      return {
        base64: response.strip,
        file_name: file_name_from_record(record),
        mimetype: mimetype_from_record(record),
        media_type: record['messageType']
      }
    end

    return if response.blank? || !response.is_a?(Hash)

    base64 = response['base64'] || response['mediaBase64'] || response['base64Data'] || response['media'] || response.dig('data', 'base64')
    return if base64.blank?

    file_name = response['fileName'] || response['filename'] || response['name'] || file_name_from_record(record)
    mimetype = response['mimetype'] || response['mimeType'] || mimetype_from_record(record) || 'application/octet-stream'
    media_type = response['mediaType'] || record['messageType']

    size = response['size'] || response.dig('data', 'size')
    file_length = size.is_a?(Hash) ? (size['fileLength'] || size['file_length'] || size[:fileLength] || size[:file_length]) : nil
    if file_length.present? && file_length.to_i > @media_max_bytes
      return {
        too_large: true,
        file_name: file_name,
        mimetype: mimetype,
        media_type: media_type,
        file_length: file_length.to_i
      }
    end

    {
      base64: base64,
      file_name: sanitize_text(file_name) || "evolution-#{source_id_for(record)}",
      mimetype: sanitize_text(mimetype) || 'application/octet-stream',
      media_type: sanitize_text(media_type),
      file_length: file_length&.to_i
    }
  end

  def attach_media!(message, record, payload)
    if payload[:too_large]
      message.update_columns(
        content: "#{message.content}\n[media too large: #{payload[:file_name]} (#{payload[:file_length]} bytes)]".strip,
        processed_message_content: "#{message.content}\n[media too large: #{payload[:file_name]} (#{payload[:file_length]} bytes)]".truncate(150_000)
      )
      return
    end

    base64 = payload[:base64].to_s
    raw = Base64.decode64(base64)
    file_name = payload[:file_name].presence || "evolution-#{source_id_for(record)}"
    content_type = payload[:mimetype].presence || 'application/octet-stream'
    file_type = attachment_file_type(content_type, payload[:media_type])

    attachment = message.attachments.create!(
      account_id: message.account_id,
      file_type: file_type,
      meta: {
        imported_from: 'evolution',
        evolution_message_type: record['messageType'],
        evolution_media_type: payload[:media_type],
        evolution_mimetype: content_type
      }
    )

    attachment.file.attach(
      io: StringIO.new(raw),
      filename: file_name,
      content_type: content_type
    )
  end

  def attachment_file_type(content_type, media_type)
    return :image if content_type.to_s.start_with?('image/')
    return :video if content_type.to_s.start_with?('video/')
    return :audio if content_type.to_s.start_with?('audio/')
    return :image if media_type.to_s == 'stickerMessage'

    :file
  end

  def message_content(record)
    message = record['message'] || {}

    sanitize_text(
      message['conversation'] ||
      message.dig('extendedTextMessage', 'text') ||
      message.dig('imageMessage', 'caption') ||
      message.dig('videoMessage', 'caption') ||
      message.dig('documentMessage', 'caption') ||
      message.dig('buttonsResponseMessage', 'selectedDisplayText') ||
      message.dig('listResponseMessage', 'title') ||
      message.dig('reactionMessage', 'text')
    ).presence || "[#{record['messageType'] || 'unsupported'}]"
  end

  def phone_number_for(chat, remote_jid)
    direct_remote_jid = [remote_jid, chat.dig('lastMessage', 'key', 'remoteJidAlt')].compact.find do |jid|
      jid.end_with?('@s.whatsapp.net')
    end
    return if direct_remote_jid.blank?

    "+#{direct_remote_jid.split('@').first}"
  end

  def fallback_name(remote_jid)
    remote_jid.to_s.split('@').first
  end

  def get_json(path)
    request(:get, path)
  end

  def post_json(path, body = nil)
    request(:post, path, body)
  end

  def request(method, path, body = nil)
    uri = URI.join("#{@evolution_base_url}/", path.sub(%r{\A/}, ''))
    request_class = method == :post ? Net::HTTP::Post : Net::HTTP::Get
    request = request_class.new(uri)
    request['apikey'] = @evolution_api_key
    request['Content-Type'] = 'application/json'
    request.body = body.to_json if body.present?

    response = Net::HTTP.start(
      uri.hostname,
      uri.port,
      use_ssl: uri.scheme == 'https'
    ) do |http|
      http.request(request)
    end

    raise "Evolution API request failed (#{response.code}) #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    body = response.body.to_s
    return if body.blank?

    JSON.parse(body)
  rescue JSON::ParserError
    body
  end

  def sanitize_url!(value)
    sanitize_text(value).to_s.delete_suffix('/')
  end

  def canonical_remote_jid(chat)
    remote_jid = sanitize_text(chat['remoteJid'])
    return if remote_jid.blank?

    return remote_jid if remote_jid.end_with?('@g.us')
    return remote_jid if remote_jid.end_with?('@s.whatsapp.net')

    alt = sanitize_text(chat.dig('lastMessage', 'key', 'remoteJidAlt'))
    return alt if alt.present? && alt.end_with?('@s.whatsapp.net')

    remote_jid
  end

  def mimetype_from_record(record)
    message = record['message'] || {}
    sanitize_text(
      message.dig('imageMessage', 'mimetype') ||
      message.dig('videoMessage', 'mimetype') ||
      message.dig('documentMessage', 'mimetype') ||
      message.dig('audioMessage', 'mimetype') ||
      message.dig('stickerMessage', 'mimetype')
    )
  end

  def file_name_from_record(record)
    message = record['message'] || {}
    sanitize_text(
      message.dig('documentMessage', 'fileName') ||
      message.dig('documentMessage', 'title') ||
      message.dig('imageMessage', 'fileName') ||
      message.dig('videoMessage', 'fileName') ||
      message.dig('audioMessage', 'fileName')
    )
  end

  def sanitize_text(value)
    return if value.nil?

    value.to_s.delete('`').strip
  end
end

EvolutionHistoryImporter.new.perform
