# OAuth Token Storage and Account Selection

## Question

Should kinko store one default Wrike OAuth account or named records for
multiple Wrike accounts and data-center hosts, and how should the CLI select a
non-default record?

## Answer

Store one default account record initially. Keep the record key scoped to
`wrike-gateway`, the OAuth client id, and the Wrike account/host as designed,
so multiple records remain representable without a migration. Defer the
non-default selection surface (for example an `--account` flag) until a real
multi-account need appears; adding it later is additive and does not change
stored record shapes. Decided on 2026-08-05 by user delegation to the
assistant's recommendation.
