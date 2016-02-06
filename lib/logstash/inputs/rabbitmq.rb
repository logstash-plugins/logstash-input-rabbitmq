# encoding: utf-8
require 'logstash/plugin_mixins/rabbitmq_connection'
require 'logstash/inputs/threadable'

module LogStash
  module Inputs
    class RabbitMQ < LogStash::Inputs::Threadable
      include ::LogStash::PluginMixins::RabbitMQConnection

      # The properties to extract from each message and store in a
      # @metadata field.
      #
      # Technically the exchange, redeliver, and routing-key
      # properties belong to the envelope and not the message but we
      # ignore that distinction here. However, we extract the
      # headers separately via get_headers even though the header
      # table technically is a message property.
      #
      # Freezing all strings so that code modifying the event's
      # @metadata field can't touch them.
      MESSAGE_PROPERTIES = [
        "app-id",
        "cluster-id",
        "consumer-tag",
        "content-encoding",
        "content-type",
        "correlation-id",
        "delivery-mode",
        "exchange",
        "expiration",
        "message-id",
        "priority",
        "redeliver",
        "reply-to",
        "routing-key",
        "timestamp",
        "type",
        "user-id",
      ].map { |s| s.freeze }.freeze

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
        @consumer = @hare_info.queue.build_consumer(:block => true,
                                                    :on_cancellation => Proc.new { on_cancellation }) do |metadata, data|
          @codec.decode(data) do |event|
            decorate(event)
            event["@metadata"]["rabbitmq_headers"] = get_headers(metadata)
            event["@metadata"]["rabbitmq_properties"] = get_properties(metadata)
            @output_queue << event if event
          end
          @hare_info.channel.ack(metadata.delivery_tag) if @ack
        end

        begin
          @hare_info.queue.subscribe_with(@consumer, :manual_ack => @ack)
        rescue MarchHare::Exception => e
          @logger.warn("Could not subscribe to queue! Will retry in #{@subscription_retry_interval_seconds} seconds", :queue => @queue)

          sleep @subscription_retry_interval_seconds
          retry
        end

        while !stop?
          sleep 1
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

      def on_cancellation
        @logger.info("Received basic.cancel from #{rabbitmq_settings[:host]}, shutting down.")
        stop
      end

      private

      # ByteArrayLongString is a private static inner class which
      # can't be access via the regular Java::SomeNameSpace::Classname
      # notation. See https://github.com/jruby/jruby/issues/3333.
      ByteArrayLongString = JavaUtilities::get_proxy_class('com.rabbitmq.client.impl.LongStringHelper$ByteArrayLongString')

      def get_header_value(value)
        # Two kinds of values require exceptional treatment:
        #
        # String values are instances of
        # com.rabbitmq.client.impl.LongStringHelper.ByteArrayLongString
        # and we don't want to propagate those.
        #
        # List values are java.util.ArrayList objects and we need to
        # recurse into them to convert any nested strings values.
        if value.class == Java::JavaUtil::ArrayList
          value.map{|item| get_header_value(item) }
        elsif value.class == ByteArrayLongString
          value.toString
        else
          value
        end
      end

      private
      def get_headers(metadata)
        if !metadata.headers.nil?
          Hash[metadata.headers.map {|k, v| [k, get_header_value(v)]}]
        else
          {}
        end
      end

      private
      def get_properties(metadata)
        MESSAGE_PROPERTIES.reduce({}) do |acc, name|
          # The method names obviously can't contain hyphens.
          value = metadata.send(name.gsub("-", "_"))
          if value
            # The AMQP 0.9.1 timestamp field only has second resolution
            # so storing milliseconds serves no purpose and might give
            # the incorrect impression of a higher resolution.
            acc[name] = name != "timestamp" ? value : value.getTime / 1000
          end
          acc
        end
      end
    end
  end
end
