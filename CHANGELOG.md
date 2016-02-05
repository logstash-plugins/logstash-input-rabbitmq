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
