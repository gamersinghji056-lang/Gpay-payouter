# Accounting Rules

## Merchant settlement
`merchant_available_inr = collection - active_frozen - merchant_settled_inr_equivalent`

INR recovered from the provider/user is a separate recovery ledger and MUST NOT reduce merchant entitlement.

## Provider recovery
`pending_from_user = collection - inr_received - user_usdt_inr_equivalent - active_frozen`

## Holding
Keep the holding formula centralized so it can be changed without duplicating logic.

All calculations shown in Admin, Merchant, Agent and User views must use the same calculation service.
