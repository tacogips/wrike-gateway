# Webhook Runtime Scope

## Question

Should `wrike-gateway` only create, inspect, update, and delete Wrike webhook
registrations, or should a future executable also host callback delivery,
signature verification, deduplication, and retry handling?

## Answer

Registration management only. `wrike-gateway` creates, inspects, updates,
suspends/resumes, and (admin tier) deletes webhook registrations but does not
host callback delivery, verify signatures, deduplicate, or retry deliveries.
Hosting a webhook receiver is a long-running server concern with its own
security and availability requirements; if it is ever needed it becomes a
separately designed executable, not an extension of the CLI binaries.
Decided on 2026-08-05 by user delegation to the assistant's recommendation.
