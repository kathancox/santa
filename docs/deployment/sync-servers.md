---
title: Sync Servers
parent: Deployment
nav_order: 3
---

# Sync Servers

Santa's [SyncBaseURL](configuration.md#sync-base-url) configuration flag allows you to synchronize with a management server, which uploads events that have occurred on the machine and downloads new rules. 

There are several open-source servers you can sync with:

* [Moroz](https://github.com/groob/moroz): A simple golang server that serves hard-coded rules from configuration files.
* [Rudolph](https://github.com/airbnb/rudolph): An AWS-based serverless sync service primarily built on API GW, DynamoDB, and Lambda components to reduce operational burden. Rudolph is designed to be fast, easy-to-use, and cost-efficient.
* [Zentral](https://github.com/zentralopensource/zentral/wiki): A centralized service that pulls data from multiple sources and deploys configurations to multiple services.
* [Zercurity](https://github.com/zercurity/zercurity): A dockerized service for managing and monitoring applications across a large fleet using Santa + Osquery.

Alternatively, `santactl` can configure rules locally without a sync server.

See the [Syncing Overview](../introduction/syncing-overview.md) page for an explanation of how syncing works in Santa.