# encoding: utf-8
require 'logstash/plugin_mixins/rabbitmq_connection'
require 'logstash/inputs/threadable'

module LogStash
  module Inputs
    class RabbitMQ < LogStash::Inputs::Threadable
      include ::LogStash::PluginMixins::RabbitMQConnection

      config_name "rabbitmq"

      # The default codec for this plugin is JSON. You can override this to suit your particular needs however.
      default :codec, "json"

      # The name of the queue Logstash will consume events from.
      config :queue, :validate => :string, :default => ""

      # Is this queue durable? (aka; Should it survive a broker restart?)
      config :durable, :validate => :boolean, :default => false

      # Should the queue be deleted on the broker when the last consumer
      # disconnects? Set this option to `false` if you want the queue to remain
      # on the broker, queueing up messages until a consumer comes along to
      # consume them.
      config :auto_delete, :validate => :boolean, :default => false

      # Is the queue exclusive? Exclusive queues can only be used by the connection
      # that declared them and will be deleted when it is closed (e.g. due to a Logstash
      # restart).
      config :exclusive, :validate => :boolean, :default => false

      # Extra queue arguments as an array.
      # To make a RabbitMQ queue mirrored, use: `{"x-ha-policy" => "all"}`
      config :arguments, :validate => :array, :default => {}

      # Prefetch count. Number of messages to prefetch
      config :prefetch_count, :validate => :number, :default => 256

      # Enable message acknowledgement
      config :ack, :validate => :boolean, :default => true

      # Passive queue creation? Useful for checking queue existance without modifying server state
      config :passive, :validate => :boolean, :default => false

      # The name of the exchange to bind the queue to.
      config :exchange, :validate => :string

      # The routing key to use when binding a queue to the exchange.
      # This is only relevant for direct or topic exchanges.
      #
      # * Routing keys are ignored on fanout exchanges.
      # * Wildcards are not valid on direct exchanges.
      config :key, :validate => :string, :default => "logstash"

      # Amount of time in seconds to wait after a failed subscription request
      # before retrying. Subscribes can fail if the server goes away and then comes back
      config :subscription_retry_interval_seconds, :validate => :number, :required => true, :default => 5

      def register
        connect!
        declare_queue!
        bind_exchange!
        @hare_info.channel.prefetch = @prefetch_count
      rescue => e
        @logger.warn("Error while setting up connection for rabbitmq input! Will retry.",
                     :message => e.message,
                     :class => e.class.name,
                     :location => e.backtrace.first)
        sleep_for_retry
        retry
      end

      def run(output_queue)
        @output_queue = output_queue
        consume!
      end

      def bind_exchange!
        if @exchange
          @hare_info.queue.bind(@exchange, :routing_key => @key)
        end
      end

      def declare_queue!
        @hare_info.queue = declare_queue()
      end

      def declare_queue
        @hare_info.channel.queue(@queue,
                                 :durable     => @durable,
                                 :auto_delete => @auto_delete,
                                 :exclusive   => @exclusive,
                                 :passive     => @passive,
                                 :arguments   => @arguments)
      end

      def consume!
        # we manually build a consumer here to be able to keep a reference to it
        # in an @ivar even though we use a blocking version of HB::Queue#subscribe

        # The logic here around resubscription might seem strange, but its predicated on the fact
        # that we rely on MarchHare to do the reconnection for us with auto_reconnect.
        # Unfortunately, while MarchHare does the reconnection work it won't re-subscribe the consumer
        # hence the logic below.
        loop do
          begin
            @consumer = @hare_info.queue.build_consumer(:block => true) do |metadata, data|
              @codec.decode(data) do |event|
                decorate(event)
                @output_queue << event if event
              end
              @hare_info.channel.ack(metadata.delivery_tag) if @ack
            end

            if @hare_info.connection.connected?
              @logger.info("Will subscribe with consumer", :config => config)
              @hare_info.queue.subscribe_with(@consumer, :manual_ack => @ack, :block => true)
              @logger.warn("Queue subscription ended! Will retry in #{@subscription_retry_interval_seconds}s", :config => config)
            else
              @logger.info("RabbitMQ connection down, will wait to retry subscription", :config => config)
            end

            break if stop?
            @consumer.gracefully_shut_down # Try to clean up gracefully
          rescue MarchHare::Exception => e
            @logger.warn("Error re-subscribing to queue!", :config => config, :message => e.message, :class => e.class.name)
          end

          Stud.stoppable_sleep(@subscription_retry_interval_seconds) { stop? }
          break if stop? # In case an error was hit before the break above was hit
        end
      end

      def stop
        super
        shutdown_consumer
        close_connection
      end

      def shutdown_consumer
        return unless @consumer
        @consumer.gracefully_shut_down
      end

    end
  end
end
