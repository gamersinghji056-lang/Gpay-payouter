# Logic Reference

## Deposit Based
Rate now: 107 base + 3% = 110.21 INR/USDT.
Confirmed deposits generate INR-equivalent collection capacity.
Merchant collection consumes capacity.
Only new confirmed USDT deposits refill deposit capacity.
Successful INR withdrawal is allowed but does not refill deposit capacity.

## Commission Based
Admin sets maximum collection limit.
Available capacity = max limit - collection + successful withdrawal, capped to max limit.
User commission = successful withdrawal * 3.5% by default.
Admin raw limit and internal model details are private from User/Merchant/Agent.

## Merchant privacy
Merchant only needs operational GPay details, QR, available collection and collection history. Funding model, admin limit, deposits, withdrawals, commission, frozen and settlement internals remain hidden.
