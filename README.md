## RabbitMQ Webhooks Plugin

This plugin provides a "webhook" functionality to a RabbitMQ broker. 
Any message processed by this plugin will be forwarded to the URL 
you configure, using the method you give it. 

Tested against RabbitMQ versions up to 3.8.2

### Changes

* 0.18 - Added ability to set `X-Webhooks-Signature` as part of webhook authentication
* 0.17 - Added basic auth from AMQP headers and messages requeue on dlhttp errors
* 0.16 - Build system changed to erlang.mk. Plugin builds and works on latest Erlang and RabbitMQ
* 0.15 - Re-built the .tar.gz file to makes sure it included the latest version of plugin code
* 0.14 - Lots better error handling and a Ruby script for generating config files
* 0.13 - Updated for use with the new plugin system in RabbitMQ 2.7
* 0.12 - Updated for use with RabbitMQ 2.3.0, now uses rebar for build
* 0.11 - Updated for use with RabbitMQ 2.2.0
* 0.9 - Incorporated patch from @cameronharris for OTP R13 compatibility, Makefile tweak
* 0.8 - Added error handling for request so bad URLs don't crash broker, fix for no message headers
* 0.7 - Added send window functionality for sending webhook requests only during specified time windows
* 0.6 - Added max_send config param for limiting how many outgoing HTTP requests happen
* 0.5 - Use RabbitMQ's worker_pool for sending requests to handle massive dumps of messages
* 0.4 - Accept more than just 200 status code for CouchDB
* 0.3 - Asynchronous HTTP send, URL and method overrideable per-message.
* 0.2 - URLs can be patterns and headers that start with "X-" get passed to REST URL.
* 0.1 - Synchronous HTTP send, no URL patterns. Rough draft.


### Running the daemon

The `Dockerfile` provides the ability to build [RabbitMQ](https://hub.docker.com/_/rabbitmq) with the management plugin installed and enabled by default, including webhooks.

```bash
docker build --tag rabbitmq-webhooks:0.18 .
docker run -d --hostname rabbitmq --name rabbitmq rabbitmq-webhooks:0.18
```

To configure your broker, download the `gen_config` script from the source tree and run it, pointing 
to a YAML file that contains your configuration (discussed below).

Copy the output of that generation to your RabbitMQ server config file (should be some place like: 
`/etc/rabbitmq/advanced.config`).

Start your broker and you should see output similar to what's discussed in the "Installing" section.

To secure webhooks, you'll need to set up your secret token using `RABBITMQ_WEBHOOKS_SECRET` environment variable. Never hardcode the token into your app!

```bash
docker run --env RABBITMQ_WEBHOOKS_SECRET=foo -d --hostname rabbitmq --name rabbitmq rabbitmq-webhooks:0.18
```

When your secret token is set, RabbitMQ uses it to create a hash signature with each payload. It will pass this hash signature along with each request in the headers as `X-Webhooks-Signature`.
To verify payload you need to compute a hash using your `RABBITMQ_WEBHOOKS_SECRET`, and ensure that the hash from RabbitMQ matches. We use an HMAC hexdigest (`sha256`) to compute the hash, you  might find a helpful example below of how to do that:

```js
import { createHmac, timingSafeEqual } from 'crypto';
import { inspect } from 'util';

// express app

app.post('/payload', (req, res) => {
  verify(req);
  res.send(`I got some JSON: ${inspect(req.body, { showHidden: false })}`);
});

const verify = (req) => {
  const signatureFromRabbit = Buffer.from(
    req.headers['x-webhooks-signature'],
    'hex'
  );
  const signature = createHmac('sha256', process.env.RABBITMQ_WEBHOOKS_SECRET)
    .update(
      `${req.headers['x-webhooks-request-timestamp']}:${JSON.stringify(
        req.body
      )}`
    )
    .digest();

  if (!timingSafeEqual(signature, signatureFromRabbit)) {
    throw new Error(`Signatures didn't match!`);
  }
};

```

### Install from Source

The build process for the webhooks plugin has changed. It now uses rebar to build.

```bash
git clone https://github.com/jbrisbin/rabbitmq-webhooks.git
cd rabbitmq-webhooks
make
make dist
```

You can now install the three .ez files required:

```bash
cp plugins/dispcount.ez $RABBITMQ_HOME/plugins
cp plugins/dlhttpc.ez $RABBITMQ_HOME/plugins
cp plugins/rabbitmq_webhooks.ez $RABBITMQ_HOME/plugins
```

When you start the broker, you should see (at the top):

```
... plugins activated:
* lhttpc-*
* rabbitmq_webhooks-*
```

and when the server is started:

```
Configuring Webhooks... done
```

Logging is done to the server log file.

### What can I use this for?

If you configure a webhook to bind to exchange "test" with routing key 
"#", any messages published with that exchange and routing key will be 
automatically sent to an HTTP URL based on pre-configured parameters, or 
by specifying overrides in the message properties and headers.

This would allow you, for example, to drop JSON data into messages in an 
AMQP queue which get sent to a REST URL via POST (or PUT or DELETE, etc...). 

Clients with no access to a CouchDB server could send batches of updates 
through RabbitMQ. The webhooks plugin then HTTP POSTs those messages to the 
CouchDB server.

If the message is successfully POST/PUT/DELETE'd to the URL, it is ACK'd 
from the queue. If there was an error, the message is NOT ACK'd and stays in 
the queue for possible later delivery. There's probably a better way to handle 
this. I'm open for suggestions! :)

### Example Configuration

There is a Ruby script (`scripts/gen_config`) you can use to translate 
a YAML config file into the more complex and finicky Erlang config file. It will generate 
the correct atoms for you to include in your system `advanced.config` file.

An example YAML file will look like this (with the bare minimum left uncommented,
everything commented out is optional and the values shown are the defaults):

```yaml
# Broker configuration
username: guest
virtual_host: /

# Use a YAML alias to reference this one exchange for all configs.
exchange: &webhook_exchange
  name: webhooks
  type: topic
  auto_delete: true
  durable: false

# Webhooks configurations
webhooks:
  -
  name: webhook1 # Name should be unique within the config file
  url: http://localhost:8000/rest
  method: post # get | post | put | delete
  exchange: *webhook_exchange
  queue:
    name: webhook1 # Best to have the queue name match the config name
    auto_delete: true
  routing_key: "#"
  max_send:
    frequency: 5
    per: second # second | minute | hour | day | week
  send_if:
    between:
      start_hour: 8 # 24-hour time
      start_min: 0
      end_hour: 17  # 24-hour time
      end_min: 0
```

If you want to configure it manually, you just need to put your config to `advanced.config`:
```
[
	{rabbitmq_webhooks, [
		{username, <<"guest">>},
		{password, <<"guest">>},
		{virtual_host, <<"/">>},
		{webhooks, [
			{test_one, [
				{url, "http://localhost:8000/rest"},
				{method, post},
				{exchange, [
					{exchange, &lt;&lt;"webhooks.test"&gt;&gt;},
					{type, &lt;&lt;"topic"&gt;&gt;},
					{auto_delete, true},
					{durable, false}
				]},
				{queue, [
					{queue, &lt;&lt;"webhooks.test.q"&gt;&gt;},
					{auto_delete, true}
				]},
				{routing_key, &lt;&lt;"#"&gt;&gt;},
				{max_send, {5, second}},
				{send_if, [{between, {13, 24}, {13, 25}}]}
			]}
		]}
	]}
].
```

### TODO

Lots and lots still to do:

* Make message sending more robust, including SSL support, authentication, 
  and several other "would be nice to have"s.
* Expose various statii to the RabbitMQ console.

### License

Licensed under the Mozilla Public License:

[http://www.rabbitmq.com/mpl.html](http://www.rabbitmq.com/mpl.html)
