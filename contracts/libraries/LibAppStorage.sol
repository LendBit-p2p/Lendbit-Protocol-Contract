// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;
import "../model/Protocol.sol";

library LibAppStorage {
    struct Layout {
        /// @dev maps collateral token to their price feed
        mapping(address token => address priceFeed) s_priceFeeds;
        /// @dev maps address of a token to see if it is loanable
        mapping(address token => bool isLoanable) s_isLoanable;
        /// @dev maps user to the value of balance he has collaterised
        mapping(address => mapping(address token => uint256 balance)) s_addressToCollateralDeposited;
        /// @dev maps user to the value of balance he has available
        mapping(address => mapping(address token => uint256 balance)) s_addressToAvailableBalance;
        ///@dev mapping the address of a user to its Struct
        mapping(address => User) addressToUser;
        ///@dev mapping of users to their address
        mapping(uint96 requestId => Request) request;
        ///@dev mapping a requestId to the collaterals used in a request
        mapping(uint96 requestId => mapping(address => uint256)) s_idToCollateralTokenAmount;
        ///@dev mapping of id to orders
        mapping(uint96 orderId => Order) order;
        ///@dev mapping of id to loanListing
        mapping(uint96 listingId => LoanListing) loanListings;
        /// @dev Collection of all colleteral Adresses
        address[] s_collateralToken;
        /// @dev all loanable assets
        address[] s_loanableToken;
        /// @dev Collection of all all the resquest;
        Request[] s_requests;
        Order[] s_order;
        /// @dev request id;
        uint96 requestId;
        uint96 s_orderId;
        uint96 listingId;
        address botAddress;
        address swapRouter;
    }
}
