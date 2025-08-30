# SSV Labs Assignment

## Key Decisions
1. Using Enumerable sets instead of just using a mapping inside the
`Provider` or `Subscriber` struct because that is a more complete
solution.
2. 

Confusions:
1. I did not use USDT/USDC (or any other stable coin) as the primary mode of payment token because the assignment asked us to use Chainlink oracle and if we already used a stable coin there is not much point in using an oracle to track its price. So, for the sake of this assignment I have used WETH.