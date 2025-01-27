module KafkaReplicator
  class TopicsReplicator
    SKIP_TOPICS = ['__consumer_offse', '__consumer_offsets', '_schemas']
    REPLICA_TAG = '"replica":true, '.freeze
    
    attr_reader :source_kafka,
                :destination_kafka,
                :source_consumer,
                :destination_producer,
                :replicated_topics,
                :skip_topics,
                :logger,
                :stopped

    def initialize(source_brokers:, destination_brokers:, skip_topics: [])
      @source_brokers = source_brokers
      @destination_brokers = destination_brokers
      @skip_topics = SKIP_TOPICS | skip_topics
      @logger = Logger.new(STDOUT)
    end

    def setup
      @stopped = false
      @replicated_topics = Set[]
      @source_consumer = nil
      @destination_producer = nil
    end

    def source_kafka
      @source_kafka ||= Kafka.new(
        @source_brokers,
        client_id: "replicator_source"
      )
    end

    def destination_kafka
      @destination_kafka ||= Kafka.new(
        @destination_brokers,
        client_id: "replicator_destination"
      )
    end

    def source_consumer
      @source_consumer ||= source_kafka.consumer(group_id: "replicator")
    end

    def destination_producer
      @destination_producer ||= destination_kafka.producer
    end

    def start
      loop do
        break if stopped

        logger.info 'Setting up configuration...'
        setup

        logger.info 'Adding topics for replication...'
        subscribe_to_source_topics

        logger.info 'Starting replication...'
        replicate
      end
    end

    def replicate
      replicate
    rescue => e
      logger.error "Exception: #{e}"
      logger.error "Exception.cause: #{e.cause.inspect}"
    end

    def stop
      logger.info 'Stopping replication...'
      source_consumer.stop
      @stopped = true
    end

    private

    def replicate
      source_consumer.each_batch(automatically_mark_as_processed: false) do |batch|
        logger.info 'New topics added, restarting...' && break unless unreplicated_topics.empty?

        batch.messages.each_slice(100).each do |messages|
          messages.each do |message|
            # skip already replicated messages
            # prevents loops in two way replication scenario
            if replica?(message.value)
              source_consumer.mark_message_as_processed(message)
              next
            end
  
            destination_producer.produce(
              mark_as_replica(message.value),
              topic: message.topic,
              partition: message.partition
            )

            source_consumer.mark_message_as_processed(message)
          end

          destination_producer.deliver_messages
          source_consumer.commit_offsets
        end
      end
    end

    def replica?(value)
      value[1..REPLICA_TAG.size] == REPLICA_TAG
    end

    def mark_as_replica(value)
      value.dup.insert(1, REPLICA_TAG)
    end
      
    def source_topics
      source_kafka.topics.reject { |topic_name| skip_topics.include?(topic_name) }.to_set
    end

    def unreplicated_topics
      source_topics - replicated_topics
    end

    def subscribe_to_source_topics
      destination_topics = destination_kafka.topics

      unreplicated_topics.each do |topic|
        source_consumer.subscribe(topic, start_from_beginning: true)
        replicated_topics << topic

        unless destination_topics.include?(topic)
          destination_kafka.create_topic(
            topic,
            num_partitions: source_kafka.partitions_for(topic),
            replication_factor: 3 # Need to be specified because otherwise ruby-kafa driver will make it equal to 1
          )
        end

        logger.info "Topic added: #{topic}"
      end
    end
  end
end
