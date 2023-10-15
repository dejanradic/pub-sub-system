// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.18;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {DateTime} from "./DateTime.sol";
import {Provider} from "./Provider.sol";

// import "hardhat/console.sol";

contract ProviderControllerImproved is Ownable {
    modifier onlyProviderOwner(uint64 providerId) {
        require(msg.sender == providers[providerId].owner());
        _;
    }

    modifier onlySubscriberOwner(uint64 subscriberId) {
        require(msg.sender == subscribers[subscriberId].owner);
        _;
    }

    struct Subscriber {
        address owner;
        uint256 balance; // the subscriber balance is stored in the contract
        string plan; // basic / premium / vip
        bool paused;
    }

    IERC20 public token;
    uint256 public minimalFee;
    uint64 providerId;
    uint64 subscriberId;

    mapping(uint64 => Provider) providers;
    mapping(uint64 => Subscriber) subscribers;
    mapping(uint64 => bool) activeProviders;
    mapping(bytes32 => bool) spentKeys;
    mapping(uint64 => uint64[]) subscriptions;

    // Events
    event ProviderAdded(
        uint64 indexed providerId,
        address indexed owner,
        bytes publicKey,
        uint256 fee,
        address providerAddress
    );
    event ProviderRemoved(uint64 indexed providerId);

    event SubscriberAdded(
        uint64 indexed subscriberId,
        address indexed owner,
        string plan,
        uint256 deposit
    );

    constructor(address _token, uint _minimalFee) {
        token = IERC20(_token);
        minimalFee = _minimalFee;
    }

    function registerProvider(
        bytes calldata registerKey,
        uint256 fee
    ) external returns (uint64 id) {
        // fee (token units) should be greater than a fixed value. Add a check
        require(fee >= minimalFee, "ProviderController: Fee to low.");
        // the system doesn't allow to register a provider with the same registerKey.
        // Implement a way to prevent it.
        bytes32 keyHash = keccak256(registerKey);
        require(!spentKeys[keyHash], "ProviderController: Key already used.");

        id = providerId;
        id++;
        Provider provider = new Provider(msg.sender, fee);
        providers[id] = provider;
        activeProviders[id] = true;
        spentKeys[keyHash] = true;
        emit ProviderAdded(id, msg.sender, registerKey, fee, address(provider));
    }

    function removeProvider(
        uint64 providerId
    ) external onlyProviderOwner(providerId) {
        // Only the owner of the Provider can remove it
        uint256 currentBalance = providers[providerId]
            .calculateProviderEarnings();

        delete providers[providerId];
        delete activeProviders[providerId];

        emit ProviderRemoved(providerId);
        if (currentBalance > 0) {
            _transferBalance(msg.sender, currentBalance);
        }
    }

    function withdrawProviderEarnings(
        uint64 providerId
    ) external onlyProviderOwner(providerId) {
        // only the owner of the provider can withdraw funds
        Provider provider = providers[providerId];
        require(
            activeProviders[providerId],
            "ProviderController: Provider not active"
        );
        // IMPORTANT: before withdrawing, the amount eraned from subscribers needs to be calculated
        uint256[] memory amounts = provider
            .calculateProviderEarningsPerSubscriber();
        uint64[] memory subscriberIds = provider.getSubscribers();
        uint amount = 0;
        for (uint i = 0; i < subscriberIds.length; i++) {
            uint balance = subscribers[subscriberIds[i]].balance;
            balance -= amounts[i];
            amount += amounts[i];
            subscribers[subscriberIds[i]].balance = balance;
        }

        if (amount > 0) {
            provider.setLastWithdrawal(
                Provider.Withdrawal(block.timestamp, amount)
            );

            _transferBalance(msg.sender, amount);
        }
    }

    function updateProvidersState(
        uint64[] calldata providerIds,
        bool[] calldata status
    ) external onlyOwner {
        // Implement the logic of this function
        // It will receive a list of provider Ids and a flag (enable /disable)
        // and update the providers state accordingly (active / inactive)
        // You can change data structures if that helps improve gas cost
        // Remember the limt of providers in the system is 200
        // Only the owner of the contract can call this function
        require(
            providerIds.length == status.length,
            "ProviderController: Provider IDs and statuses lengths must match"
        );
        for (uint i = 0; i < providerIds.length; i++) {
            bool active = activeProviders[providerIds[i]];
            if (active != status[i]) {
                if (!active) {
                    delete activeProviders[providerIds[i]];
                } else {
                    activeProviders[providerIds[i]] = true;
                }
            }
        }
    }

    function _transferBalance(address to, uint256 amount) internal {
        token.transfer(to, amount);
    }

    function resgisterSubscriber(
        uint256 deposit,
        string memory plan,
        uint64[] calldata providerIds
    ) external {
        // Only allow subscriber registrations if providers are active
        // Provider list must at least 3 and less or equals 14
        // check if the deposit amount cover expenses of providers' fees for at least 2 months
        // plan does not affect the cost of the subscription
        require(
            providerIds.length <= 14 && providerIds.length > 2,
            "ProviderController:Invalid Provider IDs size"
        );

        uint64 id = subscriberId;
        id++;
        subscriberId = id;

        uint256 tmpDeposit = deposit;

        for (uint i = 0; i < providerIds.length; i++) {
            if (activeProviders[providerIds[i]]) {
                Provider provider = providers[providerIds[i]];
                tmpDeposit -= 2 * provider.getFee();
                provider.registerSubscriber(id);
                subscriptions[id].push(providerIds[i]);
            }
        }

        subscribers[id] = Subscriber({
            owner: msg.sender,
            balance: deposit,
            plan: plan,
            paused: false
        });

        emit SubscriberAdded(id, msg.sender, plan, deposit);
        // deposit the funds
        token.transferFrom(msg.sender, address(this), deposit);
    }

    function pauseSubscription(
        uint64 subscriberId
    ) external onlySubscriberOwner(subscriberId) {
        // Only the subscriber owner can pause the subscription
        Subscriber memory subscriber = subscribers[subscriberId];
        subscriber.paused = true;

        uint64[] memory mSubscriptions = subscriptions[subscriberId];
        uint owedAmountTotal = 0;
        for (uint i = 0; i < mSubscriptions.length; i++) {
            uint64 providerId = mSubscriptions[i];
            Provider provider = providers[providerId];
            owedAmountTotal += provider.calculateProviderEarningsForSubscriber(
                subscriberId
            );
        }
        if (owedAmountTotal > subscriber.balance) {
            token.transferFrom(
                msg.sender,
                address(this),
                owedAmountTotal - subscriber.balance
            );
            subscriber.balance = 0;
        } else {
            subscriber.balance -= owedAmountTotal;
        }

        for (uint i = 0; i < mSubscriptions.length; i++) {
            uint64 providerId = mSubscriptions[i];
            Provider provider = providers[providerId];
            uint owedAmount = provider.calculateProviderEarningsForSubscriber(
                subscriberId
            );
            _transferBalance(provider.owner(), owedAmount);

            provider.removeSubscriber(subscriberId);
        }
        subscribers[subscriberId] = subscriber;
        delete subscriptions[subscriberId];

        // when the subscription is paused, it must be removed from providers list (providerSubscribers)
        // and for every provider, reduce subscriberCount

        // when pausing a subscription, the funds of the subscriber are not transferred back to the owner
    }

    function deposit(
        uint64 subscriberId,
        uint256 deposit
    ) external onlySubscriberOwner(subscriberId) {
        // Only the subscriber owner can deposit to the subscription

        uint balance = subscribers[subscriberId].balance + deposit;
        subscribers[subscriberId].balance = balance;
        token.transferFrom(msg.sender, address(this), deposit);
    }

    function getProvider(
        uint64 id
    ) external view returns (address, uint256, uint256, uint32, bool) {
        Provider provider = providers[id];
        uint32 subscriberCount = uint32(provider.getSubscribers().length);
        uint256 fee = provider.getFee();
        address owner = provider.owner();
        uint256 balance = provider.calculateProviderEarnings();
        bool active = activeProviders[id];
        return (owner, fee, balance, subscriberCount, active);
    }

    function getSubscriber(
        uint64 id
    ) external view returns (Subscriber memory) {
        return subscribers[id];
    }

    function getLiveBalance(
        uint64 subscriberId
    ) external view returns (int balance) {
        uint64[] memory mSubscriptions = subscriptions[subscriberId];
        balance = int(subscribers[subscriberId].balance);
        for (uint i = 0; i < mSubscriptions.length; i++) {
            balance -= int(providers[mSubscriptions[i]].getFee());
        }
    }
}
