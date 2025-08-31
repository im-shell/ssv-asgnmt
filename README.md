# SSV Labs Assignment

## How to run the code
```
forge build
forge compile
forge test
```

## Architecture and Decisions

### IDs for users
I chose integers to be the unique IDs for the users simply because they are cheap to produce and easy to manage. I could use another method like creating a bytes16 or bytes32 ID, something like `keccak256(user, PROVIDER_SALT)` and use this. But, it would be a bit expensive and was not needed. In production where there are other variables I could consider that too.

### Storing data for providers and subscribers
The requiremente only asked us to keep track of subscribers list for providers so I've only create an enumerable set for providers to subscribers and not vice-versa. The enumerable set allows you to do multiple actions like getting the list of subs, check if a value exists in O(1) and remove too. That's why I chose that.

### Subscription model fee calculations

The trickiest part of the whole architecture. Here the main challenge for me was to interpret the requirements. Here is what I've understood from the requirements:

1. There are many providers and many subscribers. There is a many-to-many relationship possible between them
2. Providers are services that can think like Netflix, Amazon Prime etc. and we're the subscribers.
3. The billing period is monthly and the subscribers register themselves by subscribing to at least 1 of the providers but can be more.
4. When the subscribers subscribe, they pay the first month's fee upfront. That fee is added into the balance of the providers.
5. For upcoming months - the providers have to run the `processAllSubscriptions` regularly at the start of each month in order to be able to remain fair.
    - In order to do this the providers have to call the function via an automated bot or a keeper that runs it every month.
    - If the provider does not run the function at the start of each month then there is a possibility that the amount will not deduct from the user's balance after a point. Maybe, due to lack of funds in the user's account.
6. There was a problem that the subscribers could be a very big number and processing subscription for each of them would be difficult by running a loop for all of them at once - so I added a batch processing function that can be leveraged to not go over the block gas limit (30M).
7. When the subscription is paused the user has to explicitely `resumeSubscription` in which the user would have to add funds to a specific subscription and the amount immediately credits to the provider. Just like how it happens in the `registerSubscriber()` function.
8. About transferring tokens in the contract to increase the balance - that is not possible until the token implements hooks like ERC777.

### Cons of my approach:

- Gas expensive with loops for subscription processing all at once
- Chances of hitting gas limit
- Relies on the provider to deduct at the start of each subscription cycle to keep it running

### Upgradeability and getting rid of it
Used UUPS upgradeability because it's easy to remove the functions in the next implementation of the upgrade and get rid of the upgradeability truly. We could also use Transparent proxy and just set the admin to zero address to remove upgradeability but this also works and is used more widely since in UUPS you don't have to manage admin functions and the deployment cost is lesser.

### Possible Enhancements
- Add features for subscribing or unsubscribing to a provider
- Allow the provider to change the fee with TimeController
- **Modularity**: We can create a `ValidationModule` and move the validations related to Oracle validations outside of the contract
-

## Alternate Solutions that I thought of:
### #1: Prepaid Subscriptions

This is the easiest and most effective way of subscriptions in a smart contract that is complete in itself and doesn't rely on external operator for the sake of fainrness. The users would choose providers to subscribe to and simply subscribe to them by paying upfront - the `balance` in the `Provider` struct would increase and the provider can simply withdraw that amount any time.
- It removes the need of loops
- Providers don't have to run a function to process next subscription cycle
- Average UX - users have to renew subscription every time they want to extend their subscription

The reason I didn't implement this is because it was against the requirements and there is a feature for **pausing** subscriptions which was not possible in this design.
It would be possible but with refunds then, which is complex.

### #2: Shared pool of balance but with lazy settlement
One way to make the loops less expensive is to let the subscribers do the computation for their subscription when they interact withe system, be it `increaseBalanace()` function or `subscribe()` etc. So, what it would do is mark the subscription to be processed by changing its billing cycle and the balance is credited in the provider's `balance` field. Now, when the provider is doing the processing of all subscriptions it can simply omit that one when it sees the billing timestamps. Saves on storage writes.

### #3: Per-subscription balances
Instead of having a subscriber balance we could have subscription balances. So, maintaining balance within a subscription itself. The major pro of this solution is that it prevents race condition where in shared pool if the subscriber balance is 100, and there are two providers one charges 60 and other charges 80. Both think they can charge the subscriber, but after one charges the other cannot. In this case they both can know for sure if they can charge the customer in the system as a whole and not just for themselves.

### Confusions
- I did not use USDT/USDC (or any other stable coin) as the primary mode of payment token because the assignment asked us to use Chainlink oracle and if we already used a stable coin there is not much point in using an oracle to track its price. So, for the sake of this assignment I have used WETH.