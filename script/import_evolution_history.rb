require 'json'
require 'net/http'
require 'set'
require 'uri'

class EvolutionHistoryImporter
  DEFAULT_PAGE_SIZE = 100

  def initialize
    @evolution_base_url = sanitize_url!(ENV.fetch('EVOLUTION_API_BASE_URL'))
    @evolution_api_key = ENV.fetch('EVOLUTION_API_KEY')
    @instance_name = ENV.fetch('EVOLUTION_INSTANCE')
    @account_id = ENV.fetch('CHATWOOT_ACCOUNT_ID', '1').to_i
    @page_size = ENV.fetch('EVOLUTION_PAGE_SIZE', DEFAULT_PAGE_SIZE).to_i
    @target_remote_jid = ENV['EVOLUTION_REMOTE_JID'].presence
    @imported_count = 0
    @skipped_count = 0
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
      remote_jid = chat['remoteJid']
      next if remote_jid.blank?
      next if @target_remote_jid.present? && remote_jid != @target_remote_jid

      import_chat(chat, index + 1, chats.size)
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

  def import_chat(chat, index, total)
    remote_jid = chat['remoteJid']
    records = fetch_all_messages(remote_jid)

    if records.empty?
      puts "[#{index}/#{total}] #{remote_jid}: no messages to import"
      return
    end

    records.sort_by! { |record| message_timestamp(record) || Time.at(0) }

    contact_inbox = build_contact_inbox(chat, remote_jid)
    conversation = find_or_create_conversation(contact_inbox, chat, records)
    existing_source_ids = conversation.messages.where(source_id: records.map { |record| source_id_for(record) }).pluck(:source_id).to_set

    rows = records.filter_map do |record|
      source_id = source_id_for(record)
      next if source_id.blank?
      next if existing_source_ids.include?(source_id)

      timestamp = message_timestamp(record) || Time.current
      from_me = record.dig('key', 'fromMe') == true
      content = message_content(record)

      {
        content: content,
        account_id: @account.id,
        inbox_id: @inbox.id,
        conversation_id: conversation.id,
        message_type: from_me ? Message.message_types[:outgoing] : Message.message_types[:incoming],
        private: false,
        sender_type: from_me ? nil : 'Contact',
        sender_id: from_me ? nil : contact_inbox.contact_id,
        status: from_me ? Message.statuses[:delivered] : Message.statuses[:sent],
        source_id: source_id,
        content_type: Message.content_types[:text],
        content_attributes: {
          external_created_at: timestamp,
          imported_from: 'evolution'
        },
        additional_attributes: {
          imported_from: 'evolution',
          remote_jid: remote_jid,
          evolution_message_type: record['messageType']
        },
        processed_message_content: content&.truncate(150_000),
        created_at: timestamp,
        updated_at: timestamp
      }
    end

    if rows.any?
      Message.insert_all!(rows)
      @imported_count += rows.size
    end

    @skipped_count += (records.size - rows.size)
    sync_conversation_metadata!(conversation, contact_inbox.contact, records)

    puts "[#{index}/#{total}] #{remote_jid}: imported #{rows.size}/#{records.size}"
  end

  def build_contact_inbox(chat, remote_jid)
    contact_attributes = {
      name: sanitize_text(chat['pushName']) || fallback_name(remote_jid),
      identifier: remote_jid
    }

    phone_number = phone_number_for(chat, remote_jid)
    contact_attributes[:phone_number] = phone_number if phone_number.present?

    ContactInboxWithContactBuilder.new(
      inbox: @inbox,
      source_id: remote_jid,
      contact_attributes: contact_attributes
    ).perform
  end

  def find_or_create_conversation(contact_inbox, chat, records)
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
      status: latest_from_me ? :resolved : :open,
      additional_attributes: {
        imported_from: 'evolution',
        remote_jid: chat['remoteJid']
      },
      created_at: records.first ? (message_timestamp(records.first) || latest_timestamp) : latest_timestamp,
      updated_at: latest_timestamp,
      last_activity_at: latest_timestamp,
      waiting_since: latest_from_me ? nil : latest_timestamp
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
      status: latest_from_me ? Conversation.statuses[:resolved] : Conversation.statuses[:open],
      waiting_since: latest_from_me ? nil : latest_timestamp,
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

    JSON.parse(response.body)
  end

  def sanitize_url!(value)
    sanitize_text(value).to_s.delete_suffix('/')
  end

  def sanitize_text(value)
    return if value.nil?

    value.to_s.delete('`').strip
  end
end

EvolutionHistoryImporter.new.perform
