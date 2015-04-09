rabbitmq-graphite
=================

Scrape some base info out of RabbitMQ and shove it into Graphite.

Usage
-----

    Usage: ./rabbitmq.watcher.rb [options]
        -P, --prefix [STATSD_PREFIX]     metric prefix (default: ma-lt-ian.ma.runwaynine.com)
        -i, --interval [SEC]             reporting interval (default: 10)
        -h, --host [HOST]                carbon host (default: 127.0.0.1)
        -p, --port [PORT]                carbon port (default: 8125)
        -u, --rmquser [RABBITMQ_USER]    rabbitmq user (default: guest)
        -s, --rmqpass [RABBITMQ_PASS]    rabbitmq pass (default: guest)
        -r, --rmqhost [RABBITMQ_HOST]    rabbitmq host (default: 127.0.0.1)
        -b, --rmqport [RABBITMQ_PORT]    rabbitmq port (default: 15672)
        -q, --[no-]queues                report queue metrics (default: false)
        -c, --config [CONFIG_FILE]       optional configuration file (in JSON format)

I like to put my ec2 instance id in the prefix, for example:

    rabbitmq.watcher.rb -P $(ec2metadata --instance-id)

If you don't want to expose your RabbitMQ credentials in the command line, you can
plunk them into a configuration file where the keys correspond to the command-line
flags, like so:

    {
      "prefix": "rabbitmq.testenv",
      "rmquser": "myuser",
      "rmqpass": "mypassword"
    }
