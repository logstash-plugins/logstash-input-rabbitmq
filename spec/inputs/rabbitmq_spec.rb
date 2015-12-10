# encoding: utf-8
require "logstash/devutils/rspec/spec_helper"
require "logstash/inputs/rabbitmq"
require "thread"

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

    def setup_mocks
      allow(instance).to receive(:connect!).and_call_original
      allow(::MarchHare).to receive(:connect).and_return(connection)
      allow(connection).to receive(:create_channel).and_return(channel)
      allow(connection).to receive(:on_blocked)
      allow(connection).to receive(:on_unblocked)
      allow(channel).to receive(:exchange).and_return(exchange)
      allow(channel).to receive(:queue).and_return(queue)
      allow(channel).to receive(:prefetch=)

      allow(queue).to receive(:build_consumer).with(:block => true)
      allow(queue).to receive(:subscribe_with).with(any_args)
      allow(queue).to receive(:bind).with(any_args)
    end

    # Doing this in a before block doesn't give us enough control over scope
    def register_instance
      setup_mocks
      instance.register
    end


    it "should default the codec to JSON" do
      expect(instance.codec).to be_a(LogStash::Codecs::JSON)
    end

    describe "#connect!" do
      subject { hare_info }

      it "should set the queue correctly" do
        register_instance
        expect(subject.queue).to eql(queue)
      end

      it "should set the prefetch value correctly" do
        register_instance
        expect(channel).to have_received(:prefetch=).with(123)
      end

      context "with an exchange declared" do
        @manual_register = true
        let(:exchange) { double("exchange") }
        let(:key) { double("routing key") }
        let(:rabbitmq_settings) { super.merge("exchange" => exchange, "key" => key) }

        it "should bind to the exchange" do
          register_instance
          expect(queue).to have_received(:bind).with(exchange, :routing_key => key)
        end

        context "but not immediately available" do
          before do
            setup_mocks

            i = 0
            allow(queue).to receive(:bind).with(any_args) do
              i += 1
              raise "foo" if i == 1
            end
          end

          it "should reconnect" do
            instance.register
            expect(queue).to have_received(:bind).with(any_args).twice()
          end
        end
      end
    end
  end
end

describe "with a live server", :integration => true do
  let(:klass) { LogStash::Inputs::RabbitMQ }
  let(:config) { {"host" => "127.0.0.1"} }
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
    sleep 1
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

  describe "receiving a message with a queue specified" do
    let(:queue_name) { "foo_queue" }
    let(:config) { super.merge("queue" => queue_name) }

    it "should process the message" do
      message = "Foo Message"
      q = test_channel.queue(queue_name)
      q.publish(message)

      event = output_queue.pop
      expect(event["message"]).to eql(message)
    end
  end

  describe LogStash::Inputs::RabbitMQ do
    let(:config) { super.merge("queue" => "foo_queue") }
    it_behaves_like "an interruptible input plugin" do

    end
  end
end