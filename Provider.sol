// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.18;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {DateTime} from "./DateTime.sol";

contract Provider is Ownable {
    modifier onlyOperator() {
        require(msg.sender == operator);
        _;
    }
    struct Withdrawal {
        uint256 timestamp;
        uint256 amount;
    }
    struct Fee {
        uint start;
        uint end;
        uint amount;
    }
    struct Subscription {
        uint256 index;
        uint256 timestamp;
    }

    address operator;
    Withdrawal lastWithdrawal;

    Fee[] public fees;

    uint64[] subscribers;
    mapping(uint64 => Subscription) subscriptions;

    constructor(address newOwner, uint fee) {
        operator = msg.sender;
        fees.push(
            Fee(block.timestamp, DateTime.addYears(block.timestamp, 1000), fee)
        );
        _transferOwnership(newOwner);
    }

    function registerSubscriber(uint64 id) external onlyOperator {
        require(subscriptions[id].timestamp == 0);
        subscribers.push(id);
        subscriptions[id] = Subscription(
            subscribers.length - 1,
            block.timestamp
        );
    }

    function removeSubscriber(uint64 id) external onlyOperator {
        Subscription memory subscription = subscriptions[id];
        require(subscription.timestamp > 0);
        subscribers[subscription.index] = subscribers[subscribers.length - 1];
        subscribers.pop();
    }

    function setLastWithdrawal(
        Withdrawal memory withdrawal
    ) external onlyOperator {
        lastWithdrawal = withdrawal;
        _updateFees(0, false);
    }

    function setFee(uint newFee) external onlyOwner {
        _updateFees(newFee, true);
    }

    function _updateFees(uint newFee, bool addNew) internal {
        Withdrawal memory withdrawal = lastWithdrawal;
        Fee[] memory tmpFees = fees;
        delete fees;
        for (uint i = 0; i < tmpFees.length; i++) {
            Fee memory fee = tmpFees[i];
            if (addNew && i == (tmpFees.length - 1)) {
                fee.end = block.timestamp;
            }
            if (fee.end > withdrawal.timestamp) {
                fees.push(fee);
            }
        }
        if (addNew) {
            Fee memory fee = Fee(
                block.timestamp,
                DateTime.addYears(block.timestamp, 1000),
                newFee
            );
            fees.push(fee);
        }
    }

    function calculateProviderEarnings() external view returns (uint256) {
        uint[] memory amounts = calculateProviderEarningsPerSubscriber();
        uint sum = 0;
        for (uint i = 0; i < amounts.length; i++) {
            sum += amounts[i];
        }
        return sum;
    }

    function calculateProviderEarningsPerSubscriber()
        public
        view
        returns (uint[] memory amounts)
    {
        Fee[] memory tmpFees = fees;
        amounts = new uint[](subscribers.length);
        for (uint j = 0; j < subscribers.length; j++) {
            uint subscribed = subscriptions[subscribers[j]].timestamp;
            amounts[j] += _calculateProviderEarningsForSubscriber(
                subscribed,
                tmpFees
            );
        }
    }

    function calculateProviderEarningsForSubscriber(
        uint64 subscriberId
    ) external view returns (uint) {
        Fee[] memory tmpFees = fees;
        uint subscribed = subscriptions[subscriberId].timestamp;
        return _calculateProviderEarningsForSubscriber(subscribed, tmpFees);
    }

    function _calculateProviderEarningsForSubscriber(
        uint subscribed,
        Fee[] memory tmpFees
    ) internal view returns (uint amount) {
        for (uint i = 0; i < tmpFees.length; i++) {
            uint end = i == tmpFees.length - 1
                ? block.timestamp
                : tmpFees[i].end;
            if (subscribed < tmpFees[i].start) {
                amount +=
                    tmpFees[i].amount *
                    DateTime.diffHours(tmpFees[i].start, end);
            }
            if (subscribed >= tmpFees[i].start && subscribed < tmpFees[i].end) {
                amount +=
                    tmpFees[i].amount *
                    DateTime.diffHours(subscribed, end);
            }
        }
    }

    function getSubscribers() external view returns (uint64[] memory) {
        return subscribers;
    }

    function getFee() external view returns (uint) {
        return fees[fees.length - 1].amount;
    }
}
