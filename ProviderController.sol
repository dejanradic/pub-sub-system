// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.18;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {DateTime} from "./DateTime.sol";

contract ProviderController is Ownable {
    modifier onlyProviderOwner(uint64 providerId) {
        require(msg.sender == providers[providerId].owner);
        _;
    }

    modifier onlySubscriberOwner(uint64 subscriberId) {
        require(msg.sender == subscribers[subscriberId].owner);
        _;
    }

    struct Provider {
        uint32 subscriberCount;
        uint256 fee; // fee is the cost in token units that the provider charges to subscribers per month
        address owner;
        uint256 balance; // the provider balance is stored in the contract
        bool active;
    }

    struct Subscriber {
        address owner;
        uint256 balance; // the subscriber balance is stored in the contract
        string plan; // basic / premium / vip
        bool paused;
    }
    struct Withdrawal {
        uint128 year;
        uint128 month;
        uint256 amount;
    }

    IERC20 token;
    uint256 minimalFee;
    uint64 private constant MAX_NUMBER_PROVIDERS = 200;
    uint64 providerId;
    uint64 subscriberId;
    uint64 providerCount;
    mapping(uint64 => Provider) providers;
    mapping(uint64 => Subscriber) subscribers;
    mapping(uint64 => uint64[]) providerSubscribers;
    mapping(bytes32 => bool) spentKeys;
    mapping(uint64 => Withdrawal) providerWithdrawals;
    mapping(uint64 => uint64[]) subscriptions;

    // Events
    event ProviderAdded(
        uint64 indexed providerId,
        address indexed owner,
        bytes publicKey,
        uint256 fee
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
        // check MAX_NUMBER_PROVIDERS is not surpassed
        uint64 tmpProviderCount = providerCount;
        tmpProviderCount++;
        require(
            tmpProviderCount < MAX_NUMBER_PROVIDERS,
            "ProviderController: Maximal number of provider excided"
        );
        providerCount = tmpProviderCount;
        // fee (token units) should be greater than a fixed value. Add a check
        require(fee >= minimalFee, "ProviderController: Fee to low.");
        // the system doesn't allow to register a provider with the same registerKey.
        // Implement a way to prevent it.
        bytes32 keyHash = keccak256(registerKey);
        require(!spentKeys[keyHash], "ProviderController: Key already used.");

        id = providerId;
        id++;
        providerId = id;
        providers[id] = Provider({
            owner: msg.sender,
            balance: 0,
            subscriberCount: 0,
            fee: fee,
            active: true
        });
        spentKeys[keyHash] = true;
        emit ProviderAdded(id, msg.sender, registerKey, fee);
    }

    function removeProvider(
        uint64 providerId
    ) external onlyProviderOwner(providerId) {
        // Only the owner of the Provider can remove it

        // improve gas cost
        uint256 currentBalance = providers[providerId].balance;

        delete providers[providerId];
        uint64 tmpProviderCount = providerCount;
        tmpProviderCount--;
        providerCount = tmpProviderCount;

        emit ProviderRemoved(providerId);
        if (currentBalance > 0) {
            _transferBalance(msg.sender, currentBalance);
        }
    }

    function withdrawProviderEarnings(
        uint64 providerId
    ) external onlyProviderOwner(providerId) {
        // only the owner of the provider can withdraw funds
        Provider memory provider = providers[providerId];
        require(provider.active, "ProviderController: Provider not active");

        // IMPORTANT: before withdrawing, the amount eraned from subscribers needs to be calculated
        uint256 amount = calculateProviderEarnings(provider);
        uint256 perSubscriber = amount / provider.subscriberCount;
        uint64[] memory subscriberIds = providerSubscribers[providerId];
        for (uint i = 0; i < subscriberIds.length; i++) {
            uint balance = subscribers[subscriberIds[i]].balance;
            balance -= perSubscriber;
            subscribers[subscriberIds[i]].balance = balance;
        }

        providerWithdrawals[providerId] = Withdrawal(
            uint128(DateTime.getYear(block.timestamp)),
            uint128(DateTime.getMonth(block.timestamp)),
            amount
        );

        _transferBalance(msg.sender, amount);
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
            providerIds.length < MAX_NUMBER_PROVIDERS,
            "ProviderController: Maximal number of provider excided"
        );
        require(
            providerIds.length == status.length,
            "ProviderController: Provider IDs and statuses lengths must match"
        );
        for (uint i = 0; i < providerIds.length; i++) {
            Provider memory provider = providers[providerIds[i]];
            if (provider.active != status[i]) {
                providers[providerIds[i]].active = status[i];
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

        require(providerIds.length <= 14 && providerIds.length > 2,"ProviderController:Invalid Provider IDs size");

        uint64 id = subscriberId;
        id++;
        subscriberId = id;

        uint256 tmpDeposit = deposit;

        for (uint i = 0; i < providerIds.length; i++) {
            Provider memory provider = providers[providerIds[i]];
            if (provider.active) {
                tmpDeposit -= 2 * provider.fee;
                provider.subscriberCount++;
                providerSubscribers[providerIds[i]].push(id);
                providers[providerIds[i]] = provider;
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
        subscribers[subscriberId].paused = true;
        delete subscribers[subscriberId];
        uint64[] memory mSubscriptions = subscriptions[subscriberId];
        for (uint i = 0; i < mSubscriptions.length; i++) {
            uint64 providerId = mSubscriptions[i];
            uint32 subscriberCount = providers[providerId].subscriberCount;
            subscriberCount--;
            providers[providerId].subscriberCount = subscriberCount;

            uint64[] memory mSubscribers = providerSubscribers[providerId];
            uint index = _getIndex(mSubscribers, subscriberId);
            if (index < mSubscribers.length) {
                uint64 last = mSubscribers[mSubscribers.length - 1];
                providerSubscribers[providerId][index] = last;
                providerSubscribers[providerId].pop();
            }
        }

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

    function calculateProviderEarnings(
        Provider memory provider
    ) public view returns (uint256) {
                // Calculate the earnings for a given provider based on subscribers count and provider fee
        // The calculation is made on a full month basis.
        uint256 yearNow = DateTime.getYear(block.timestamp);
        uint256 monthNow = DateTime.getMonth(block.timestamp);
        Withdrawal memory withdrawal = providerWithdrawals[providerId];
        uint pased = 12 *
            (yearNow - withdrawal.year) +
            monthNow -
            withdrawal.month;
        if (pased == 0) {
            return 0;
        }

        return pased * provider.fee * provider.subscriberCount;
    }

    function calculateProviderEarningsById(
        uint64 providerId
    ) public view returns (uint256) {
        Provider memory provider = providers[providerId];
        return calculateProviderEarnings(provider);
    }

    function _getIndex(
        uint64[] memory array,
        uint value
    ) internal view returns (uint) {
        for (uint i = 0; i < array.length; i++) {
            if (array[i] == value) {
                return i;
            }
        }
        return array.length;
    }

    function getProvider(
        uint64 id
    ) external view returns (Provider memory provider) {
        provider = providers[id];
        provider.balance = calculateProviderEarnings(provider);
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
            balance -= int(providers[mSubscriptions[i]].fee);
        }
    }
}
