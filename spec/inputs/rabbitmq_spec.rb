# encoding: utf-8
require "logstash/devutils/rspec/spec_helper"
require "logstash/inputs/rabbitmq"
require "thread"
require 'logstash/event'

Thread.abort_on_exception = true

describe LogStash::Inputs::RabbitMQ do
  let(:klass) { LogStash::Inputs::RabbitMQ }
  let(:host) { "localhost" }
  let(:port) { 5672 }
  let(:exchange_type) { "topic" }
  let(:exchange) { "myexchange" }
  let(:queue) { "myqueue" }
  let(:rabbitmq_settings) {
    {
      "host" => host,
      "port" => port,
      "queue" => queue,
      "prefetch_count" => 123
    }
  }
  let(:instance) { klass.new(rabbitmq_settings) }
  let(:hare_info) { instance.instance_variable_get(:@hare_info) }

  context "when connected" do
    let(:connection) { double("MarchHare Connection") }
    let(:channel) { double("Channel") }
    let(:exchange) { double("Exchange") }
    let(:channel) { double("Channel") }
    let(:queue) { double("queue") }

    # Doing this in a before block doesn't give us enough control over scope
    before do
      allow(instance).to receive(:connect!).and_call_original
      allow(::MarchHare).to receive(:connect).and_return(connection)
      allow(connection).to receive(:create_channel).and_return(channel)
      allow(connection).to receive(:on_shutdown)
      allow(connection).to receive(:on_blocked)
      allow(connection).to receive(:on_unblocked)
      allow(channel).to receive(:exchange).and_return(exchange)
      allow(channel).to receive(:queue).and_return(queue)
      allow(channel).to receive(:prefetch=)

      allow(queue).to receive(:build_consumer).with(:on_cancellation => anything)
      allow(queue).to receive(:subscribe_with).with(any_args)
      allow(queue).to receive(:bind).with(any_args)
    end

    it "should default the codec to JSON" do
      expect(instance.codec).to be_a(LogStash::Codecs::JSON)
    end

    describe "#connect!" do
      subject { hare_info }

      context "without an exchange declared" do
        before do
          instance.register
          instance.setup!
        end

        it "should set the queue correctly" do
          expect(subject.queue).to eql(queue)
        end

        it "should set the prefetch value correctly" do
          expect(channel).to have_received(:prefetch=).with(123)
        end
      end

      context "with an exchange declared" do
        let(:exchange) { "exchange" }
        let(:key) { "routing key" }
        let(:rabbitmq_settings) { super.merge("exchange" => exchange, "key" => key, "exchange_type" => "fanout") }

        before do
          allow(instance).to receive(:declare_exchange!)
        end

        context "on run" do
          before do
            instance.register
            instance.setup!
          end

          it "should bind to the exchange" do
            expect(queue).to have_received(:bind).with(exchange, :routing_key => key)
          end

          it "should declare the exchange" do
            expect(instance).to have_received(:declare_exchange!)
          end
        end

        context "but not immediately available" do
          before do
            i = 0
            allow(queue).to receive(:bind).with(any_args) do
              i += 1
              raise "foo" if i == 1
            end
          end

          it "should reconnect" do
            instance.register
            instance.setup!
            expect(queue).to have_received(:bind).with(any_args).twice()
          end
        end

        context "initially unable to subscribe" do
          before do
            i = 0
            allow(queue).to receive(:subscribe_with).with(any_args) do
              i += 1
              raise "sub error" if i == 1
            end

            it "should retry the subscribe" do
              expect(queue).to have_receive(:subscribe_with).twice()
            end
          end
        end
      end
    end
  end
end

describe "with a live server", :integration => true do
  let(:klass) { LogStash::Inputs::RabbitMQ }
  let(:config) { {"host" => "127.0.0.1", "auto_delete" => true, "codec" => "plain", "add_field" => {"[@metadata][foo]" => "bar"} } }
  let(:instance) { klass.new(config) }
  let(:hare_info) { instance.instance_variable_get(:@hare_info) }
  let(:output_queue) { Queue.new }

  # Spawn a connection in the bg and wait up (n) seconds
  def spawn_and_wait(instance)
    instance.register

    output_queue # materialize in this thread

    Thread.new {
      instance.run(output_queue)
    }

    20.times do
      instance.connected? ? break : sleep(0.1)
    end

    # Extra time to make sure the consumer can attach
    # Without this there's a chance the shutdown code will execute
    # before consumption begins. This is tricky to do more elegantly
    sleep 4
  end

  let(:test_connection) { MarchHare.connect(instance.send(:rabbitmq_settings)) }
  let(:test_channel) { test_connection.create_channel }

  before do
    # Materialize the instance in the current thread to prevent dupes
    # If you use multiple threads with lazy evaluation weird stuff happens
    instance
    spawn_and_wait(instance)

    test_channel # Start up the test client as well
  end

  after do
    instance.stop()
    test_channel.close
    test_connection.close
  end

  context "using defaults" do
    it "should start, connect, and stop cleanly" do
      expect(instance.connected?).to be_truthy
    end
  end

  it "should have the correct prefetch value" do
    expect(instance.instance_variable_get(:@hare_info).channel.prefetch).to eql(256)
  end

  describe "receiving a message with a queue + exchange specified" do
    let(:config) { super.merge("queue" => queue_name, "exchange" => exchange_name, "exchange_type" => "fanout", "metadata_enabled" => true) }
    let(:event) { output_queue.pop }
    let(:exchange) { test_channel.exchange(exchange_name, :type => "fanout") }
    let(:exchange_name) { "logstash-input-rabbitmq-#{rand(0xFFFFFFFF)}" }
    #let(:queue) { test_channel.queue(queue_name, :auto_delete => true) }
    let(:queue_name) { "logstash-input-rabbitmq-#{rand(0xFFFFFFFF)}" }

    after do
      exchange.delete
    end

    context "when the message has a payload but no message headers" do
      before do
        exchange.publish(message)
      end

      let(:message) { "Foo Message" }

      it "should process the message and store the payload" do
        expect(event.get("message")).to eql(message)
      end

      it "should save an empty message header hash" do
        expect(event).to include("@metadata")
        expect(event.get("@metadata")).to include("rabbitmq_headers")
        expect(event.get("[@metadata][rabbitmq_headers]")).to eq({})
      end
    end

    context "when message properties are available" do
      before do
        # Don't test every single property but select a few with
        # different characteristics to get sufficient coverage.
        exchange.publish("",
                      :properties => {
                        :app_id    => app_id,
                        :timestamp => Java::JavaUtil::Date.new(epoch * 1000),
                        :priority  => priority,
                      })
      end

      let(:app_id) { "myapplication" }
      # Randomize the epoch we test with but limit its range to signed
      # ints to not assume all protocols and libraries involved use
      # unsigned ints for epoch values.
      let(:epoch) { rand(0x7FFFFFFF) }
      let(:priority) { 5 }

      it "should save message properties into a @metadata field" do
        expect(event).to include("@metadata")
        expect(event.get("@metadata")).to include("rabbitmq_properties")

        props = event.get("[@metadata][rabbitmq_properties")
        expect(props["app-id"]).to eq(app_id)
        expect(props["delivery-mode"]).to eq(1)
        expect(props["exchange"]).to eq(exchange_name)
        expect(props["priority"]).to eq(priority)
        expect(props["routing-key"]).to eq("")
        expect(props["timestamp"]).to eq(epoch)
      end
    end

    context "when message headers are available" do
      before do
        exchange.publish("", :properties => { :headers => headers })
      end

      let (:headers) {
        {
          "arrayvalue"  => [true, 123, "foo"],
          "boolvalue"   => true,
          "intvalue"    => 123,
          "stringvalue" => "foo",
        }
      }

      it "should save message headers into a @metadata field" do
        expect(event).to include("@metadata")
        expect(event.get("@metadata")).to include("rabbitmq_headers")
        expect(event.get("[@metadata][rabbitmq_headers]")).to include(headers)
      end

      it "should properly decorate the event" do
        expect(event.get("[@metadata][foo]")).to eq("bar")
      end
    end
  end

  describe LogStash::Inputs::RabbitMQ do
    it_behaves_like "an interruptible input plugin"
  end
end
