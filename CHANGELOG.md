## 4.1.0
 - Depend on new mixin with fixed TLS options
## 4.0.1
 - Depend on logstash-core-plugin-api instead of logstash-core, removing the need to mass update plugins on major releases of logstash
## 4.0.0
 - Ensure the consumer is done processing messages before closing channel. Fixes shutdown errors.
 - Use an internal queue + separate thread to accelerate processing
 - Disable metadata insertion by default, this slows things down majorly
 - Make exchange_type an optional config option with using 'exchange'. 
   When used the exchange will always be declared

## 3.3.1
  - New dependency requirements for logstash-core for the 5.0 release

## 3.3.0
 - Fix a regression in 3.2.0 that reinstated behavior that duplicated consumers
 - Always declare exchanges used, the exchange now need not exist before LS starts
 - Allow a precise specification of the exchange type

## 3.2.0
 - The properties and headers of the messages are now saved in the [@metadata][rabbitmq_headers] and [@metadata][rabbitmq_properties] fields.
 - Logstash now shuts down if the server sends a basic.cancel method.
 - Reinstating the overview documentation that was lost in 3.0.0 and updating it to be clearer.
 - Internal: Various spec improvements that decrease flakiness and eliminate the queue littering of the integration test RabbitMQ instance.

## 3.1.5
 - Fix a bug where when reconnecting a duplicate consumer would be created

## 3.1.4
 - Fix a bug where this plugin would not properly reconnect if it lost its connection to the server while the connection would re-establish itself, the queue subscription would not

## 3.1.3
 - Fix a spec that shouldn't have broken with LS2.2
## 3.1.2
 - Upgrade march hare version to fix file perms issue
## 3.1.1
 - Default codec setting should have been JSON

## 3.1.0
 - Fix broken prefetch count parameter

## 3.0.2
 - Bump dependency on logstash-mixin-rabbitmq_connection

## 3.0.0
 - Plugins were updated to follow the new shutdown semantic, this mainly allows Logstash to instruct input plugins to terminate gracefully,
   instead of using Thread.raise on the plugins' threads. Ref: https://github.com/elastic/logstash/pull/3895
 - Dependency on logstash-core update to 2.0

* 2.0.0
  - Massive refactor
  - Implement Logstash 2.x stop behavior
  - Fix reconnect issues
  - Depend on rabbitmq_connection mixin for most connection functionality
* 1.1.1
  - Bump march hare to 2.12.0 which fixes jar perms on unices
* 1.1.0
  - Bump march hare version to 2.11.0
