// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import { AggregatorV3Interface } from "../interfaces/AggregatorV3Interface.sol";

// Mock Chainlink Price Feed for testing
contract MockPriceFeed is AggregatorV3Interface {
    int256 private _price;
    uint8 private _decimals;

    constructor(int256 price, uint8 decimals_) {
        _price = price;
        _decimals = decimals_;
    }

    function setPrice(int256 price) external {
        _price = price;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, _price, block.timestamp, block.timestamp, 1);
    }

    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _price, block.timestamp, block.timestamp, _roundId);
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function description() external pure returns (string memory) {
        return "Mock ETH/USD Price Feed";
    }

    function version() external pure returns (uint256) {
        return 1;
    }
}
