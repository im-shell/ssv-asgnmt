// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.27;

import { SubscriptionService } from "../../src/SubscriptionService.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

contract SubscriptionServiceScript is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address weth = vm.envAddress("WETH");
        address priceFeed = vm.envAddress("PRICE_FEED");

        console.log("Deploying SubscriptionService with UUPS proxy...");
        console.log("Deployer address:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy implementation contract
        SubscriptionService implementation = new SubscriptionService();
        console.log("Implementation deployed to:", address(implementation));

        // Prepare initialization data
        bytes memory initData = abi.encodeWithSelector(
            SubscriptionService.initialize.selector,
            WETH,
            priceFeed
        );

        // Deploy proxy with implementation and initialization
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        console.log("Proxy deployed to:", address(proxy));

        // Get the initialized contract instance
        SubscriptionService strategy = SubscriptionService(payable(address(proxy)));

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("Implementation:", address(implementation));
        console.log("Proxy:", address(proxy));
    }
}
