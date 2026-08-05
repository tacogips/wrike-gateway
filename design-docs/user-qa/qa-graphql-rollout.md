# GraphQL Contract Rollout

## Question

Should the first stable GraphQL release expose all twelve designed resource
families, or stabilize a smaller task-centric slice before adding account
administration, workflows, and webhooks?

## Answer

Expose all twelve designed resource families in the first stable release,
implemented resource family by resource family as planned in
`impl-plans/active/wrike-gateway-initial-implementation.md`. A field becomes
part of the stable contract only when its capability reaches the
`implemented` coverage state, so stability phases in per capability rather
than through a separate pre-release slice. Decided on 2026-08-05 by user
delegation to the assistant's recommendation.
