// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.9;
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import  "../../lib/chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {Constants} from "../utils/constants/constant.sol";
import {Validator} from "../utils/validators/Validator.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import  "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "../utils/validators/Error.sol";
import "../model/Event.sol";
import "../model/Protocol.sol";
import "../interfaces/IUniswapV2Router02.sol";      

import "../utils/functions/Utils.sol";

/// @title ProtocolFacet Contract
/// @author Chukwuma Emmanuel(@ebukizy1). Favour Aniogor (@SuperDevFavour)
contract ProtocolFacet {
    LibAppStorage.Layout internal _appStorage;

    //////////////////
    /// Modifiers ///
    ////////////////

    /**
     * @dev Ensures that the provided token is allowed by checking
     *  if a price feed exists for it in the protocol
     * @param _token The address of the token to be verified
     */
    modifier _isTokenAllowed(address _token) {
        if (_appStorage.s_priceFeeds[_token] == address(0)) {
            revert Protocol__TokenNotAllowed();
        }
        _;
    }

    /**
     * @dev Ensures that the provided amount is greater than zero
     * @param _amount The amount to be validated
     */
    modifier _moreThanZero(uint256 _amount) {
        if (_amount <= 0) {
            revert Protocol__MustBeMoreThanZero();
        }
        _;
    }

    /**
     * @dev Ensures that the provided amount Of the Native Token passed is greater than zero
     * @param _token The address of the token to be validated
     */
    modifier _nativeMoreThanZero(address _token) {
        if (_token == Constants.NATIVE_TOKEN && msg.value <= 0) {
            revert Protocol__MustBeMoreThanZero();
        }
        _;
    }

    /**
     * @dev Ensure that only bot address can call this function
     * @param _requestId the id of the request that will be liquidate
     */
    modifier onlyBot(uint96 _requestId) {
        if (_appStorage.botAddress != msg.sender) {
            revert Protocol__OnlyBotCanAccess();
        }

        if (_requestId <= 0) {
            revert Protocol__MustBeMoreThanZero();
        }
        _;
    }

    /**
     * @dev Ensures that the provided amount is greater than zero for depositing and withdraeing
     * @param _amount The amount to be validated
     * @param _token The address of the token to be validated
     */
    modifier _valueMoreThanZero(uint256 _amount, address _token) {
        if (_amount <= 0) {
            revert Protocol__MustBeMoreThanZero();
        }
        if (_token == Constants.NATIVE_TOKEN && msg.value <= 0) {
            revert Protocol__MustBeMoreThanZero();
        }
        _;
    }

    //////////////////
    /// FUNCTIONS ///
    ////////////////

    /// @param _tokenCollateralAddress The address of the token to deposit as collateral
    /// @param _amountOfCollateral The amount of collateral to deposit
    function depositCollateral(
        address _tokenCollateralAddress,
        uint256 _amountOfCollateral
    )
        external
        payable
        _valueMoreThanZero(_amountOfCollateral, _tokenCollateralAddress)
        _isTokenAllowed(_tokenCollateralAddress)
    {
        if (_tokenCollateralAddress == Constants.NATIVE_TOKEN) {
            _amountOfCollateral = msg.value;
        }

        _appStorage.s_addressToCollateralDeposited[msg.sender][
            _tokenCollateralAddress
        ] += _amountOfCollateral;
        _appStorage.s_addressToAvailableBalance[msg.sender][
            _tokenCollateralAddress
        ] += _amountOfCollateral;

        if (_tokenCollateralAddress != Constants.NATIVE_TOKEN) {
            bool _success = IERC20(_tokenCollateralAddress).transferFrom(
                msg.sender,
                address(this),
                _amountOfCollateral
            );
            if (!_success) {
                revert Protocol__TransferFailed();
            }
        }
        emit CollateralDeposited(
            msg.sender,
            _tokenCollateralAddress,
            _amountOfCollateral
        );
    }

    /**
     * @notice Creates a request for a loan
     * @param _amount The principal amount of the loan
     * @param _interest The annual interest rate of the loan (in percentage points)
     * @param _returnDate The unix timestamp by when the loan should be repaid
     * @param _loanCurrency The currency in which the loan is denominated
     * @dev This function calculates the required repayments and checks the borrower's collateral before accepting a loan request.
     */
    function createLendingRequest(
        uint128 _amount,
        uint16 _interest,
        uint256 _returnDate,
        address _loanCurrency
    ) external _moreThanZero(_amount) {
        if (!_appStorage.s_isLoanable[_loanCurrency]) {
            revert Protocol__TokenNotLoanable();
        }

        if ((_returnDate - block.timestamp) < 1 days) {
            revert Protocol__DateMustBeInFuture();
        }

        //get token decimal
        uint8 decimal = _getTokenDecimal(_loanCurrency);

        //get usd value
        uint256 _loanUsdValue = getUsdValue(_loanCurrency, _amount, decimal);

        if (_loanUsdValue < 1) revert Protocol__InvalidAmount();

        uint256 collateralValueInLoanCurrency = getAccountCollateralValue(
            msg.sender
        );

        uint256 maxLoanableAmount = (collateralValueInLoanCurrency *
            Constants.COLLATERALIZATION_RATIO) / 100;

        if (
            _appStorage.addressToUser[msg.sender].totalLoanCollected +
                _loanUsdValue >=
            maxLoanableAmount
        ) {
            revert Protocol__InsufficientCollateral();
        }
        //
        address[] memory _collateralTokens = getUserCollateralTokens(
            msg.sender
        );

        _appStorage.requestId = _appStorage.requestId + 1;
        Request storage _newRequest = _appStorage.request[
            _appStorage.requestId
        ];
        _newRequest.requestId = _appStorage.requestId;
        _newRequest.author = msg.sender;
        _newRequest.amount = _amount;
        _newRequest.interest = _interest;
        _newRequest.returnDate = _returnDate;
        _newRequest.totalRepayment = _calculateLoanInterest(
            _returnDate,
            _amount,
            _interest
        );
        _newRequest.loanRequestAddr = _loanCurrency;
        _newRequest.collateralTokens = _collateralTokens;
        _newRequest.status = Status.OPEN;

        uint256 collateralToLock = (_loanUsdValue * 100 * Constants.PRECISION) /
            maxLoanableAmount; // Account for 80% LTV

        for (uint256 i = 0; i < _collateralTokens.length; i++) {
            address token = _collateralTokens[i];
            uint8 _decimalToken = _getTokenDecimal(token);
            uint256 userBalance = _appStorage.s_addressToCollateralDeposited[
                msg.sender
            ][token];

            // Calculate the amount to lock for each token based on its proportion of the total collateral
            uint256 amountToLockUSD = (getUsdValue(
                token,
                userBalance,
                _decimalToken
            ) * collateralToLock) / 100;
            uint256 amountToLock = ((((amountToLockUSD) * 10) /
                getUsdValue(token, 10, 0)) * (10 ** _decimalToken)) /
                Constants.PRECISION;
            _appStorage.s_idToCollateralTokenAmount[_appStorage.requestId][
                token
            ] = amountToLock;
        }
        _appStorage.s_requests.push(_newRequest);

        emit RequestCreated(
            msg.sender,
            _appStorage.requestId,
            _amount,
            _interest
        );
    }

    /// @notice Directly services a lending request by transferring funds to the borrower
    /// @param _requestId Identifier of the request being serviced
    /// @param _tokenAddress Token in which the funds are being transferred
    function serviceRequest(
        uint96 _requestId,
        address _tokenAddress
    ) external payable _nativeMoreThanZero(_tokenAddress) {
        Request storage _foundRequest = _appStorage.request[_requestId];
        Request storage _Request = _appStorage.s_requests[_requestId - 1];

        if (_foundRequest.status != Status.OPEN)
            revert Protocol__RequestNotOpen();
        if (_foundRequest.loanRequestAddr != _tokenAddress)
            revert Protocol__InvalidToken();
        if (_foundRequest.author == msg.sender) {
            revert Protocol__CantFundSelf();
        }
        if (_foundRequest.returnDate <= block.timestamp) {
            revert Protocol__RequestExpired();
        }

        _foundRequest.lender = msg.sender;
        _Request.lender = msg.sender;
        _foundRequest.status = Status.SERVICED;
        _Request.status = Status.SERVICED;
        uint256 amountToLend = _foundRequest.amount;

        // Check if the lender has enough balance and the allowance to transfer the tokens
        if (_tokenAddress == Constants.NATIVE_TOKEN) {
            if (msg.value < amountToLend) {
                revert Protocol__InsufficientAmount();
            }
        } else {
            if (IERC20(_tokenAddress).balanceOf(msg.sender) < amountToLend)
                revert Protocol__InsufficientBalance();
            if (
                IERC20(_tokenAddress).allowance(msg.sender, address(this)) <
                amountToLend
            ) revert Protocol__InsufficientAllowance();
        }

        uint8 _decimalToken = _getTokenDecimal(_tokenAddress);
        uint256 _loanUsdValue = getUsdValue(
            _tokenAddress,
            amountToLend,
            _decimalToken
        );

        uint256 _totalRepayment = amountToLend +
            _calculateLoanInterest(
                _foundRequest.returnDate,
                _foundRequest.amount,
                _foundRequest.interest
            );
        _foundRequest.totalRepayment = _totalRepayment;
        _appStorage
            .addressToUser[_foundRequest.author]
            .totalLoanCollected += _totalRepayment;

        if (_healthFactor(_foundRequest.author, _loanUsdValue) < 1) {
            revert Protocol__InsufficientCollateral();
        }

        // Update the request's status to serviced
        _appStorage
            .addressToUser[msg.sender]
            .totalLoanCollected += _loanUsdValue;

        for (uint i = 0; i < _foundRequest.collateralTokens.length; i++) {
            _appStorage.s_addressToAvailableBalance[_foundRequest.author][
                _foundRequest.collateralTokens[i]
            ] =
                _appStorage.s_addressToAvailableBalance[_foundRequest.author][
                    _foundRequest.collateralTokens[i]
                ] -
                _appStorage.s_idToCollateralTokenAmount[_requestId][
                    _foundRequest.collateralTokens[i]
                ];
        }

        // Transfer the funds from the lender to the borrower
        if (_tokenAddress != Constants.NATIVE_TOKEN) {
            bool success = IERC20(_tokenAddress).transferFrom(
                msg.sender,
                _foundRequest.author,
                amountToLend
            );
            require(success, "Protocol__TransferFailed");
        } else {
            (bool sent, ) = payable(_foundRequest.author).call{
                value: amountToLend
            }("");
            require(sent, "Protocol__TransferFailed");
        }

        // Emit a success event with relevant details
        emit RequestServiced(
            _requestId,
            msg.sender,
            _foundRequest.author,
            amountToLend
        );
    }

    /// @notice Withdraws collateral from the protocol
    /// @param _tokenCollateralAddress Address of the collateral token
    /// @param _amount Amount of collateral to withdraw
    function withdrawCollateral(
        address _tokenCollateralAddress,
        uint128 _amount
    ) external _isTokenAllowed(_tokenCollateralAddress) _moreThanZero(_amount) {
        uint256 depositedAmount = _appStorage.s_addressToAvailableBalance[
            msg.sender
        ][_tokenCollateralAddress];

        if (depositedAmount < _amount) {
            revert Protocol__InsufficientCollateralDeposited();
        }

        _appStorage.s_addressToCollateralDeposited[msg.sender][
            _tokenCollateralAddress
        ] -= _amount;
        _appStorage.s_addressToAvailableBalance[msg.sender][
            _tokenCollateralAddress
        ] -= _amount;

        if (_tokenCollateralAddress == Constants.NATIVE_TOKEN) {
            (bool sent, ) = payable(msg.sender).call{value: _amount}("");
            require(sent, "Protocol__TransferFailed");
        } else {
            bool success = IERC20(_tokenCollateralAddress).transfer(
                msg.sender,
                _amount
            );
            require(success, "Protocol__TransferFailed");
        }
        emit CollateralWithdrawn(msg.sender, _tokenCollateralAddress, _amount);
    }

    /// @notice Adds new collateral tokens to the protocol
    /// @param _tokens Array of new collateral token addresses
    /// @param _priceFeeds Array of price feed addresses for the new collateral tokens
    function addCollateralTokens(
        address[] memory _tokens,
        address[] memory _priceFeeds
    ) external {
        LibDiamond.enforceIsContractOwner();

        if (_tokens.length != _priceFeeds.length) {
            revert Protocol__tokensAndPriceFeedsArrayMustBeSameLength();
        }
        for (uint8 i = 0; i < _tokens.length; i++) {
            _appStorage.s_priceFeeds[_tokens[i]] = _priceFeeds[i];
            _appStorage.s_collateralToken.push(_tokens[i]);
        }
        emit UpdatedCollateralTokens(
            msg.sender,
            uint8(_appStorage.s_collateralToken.length)
        );
    }

    /// @notice Removes collateral tokens from the protocol
    /// @param _tokens Array of collateral token addresses to remove
    function removeCollateralTokens(address[] memory _tokens) external {
        LibDiamond.enforceIsContractOwner();

        for (uint8 i = 0; i < _tokens.length; i++) {
            _appStorage.s_priceFeeds[_tokens[i]] = address(0);
            for (uint8 j = 0; j < _appStorage.s_collateralToken.length; j++) {
                if (_appStorage.s_collateralToken[j] == _tokens[i]) {
                    _appStorage.s_collateralToken[j] = _appStorage
                        .s_collateralToken[
                            _appStorage.s_collateralToken.length - 1
                        ];
                    _appStorage.s_collateralToken.pop();
                }
            }
        }
        emit UpdatedCollateralTokens(
            msg.sender,
            uint8(_appStorage.s_collateralToken.length)
        );
    }

    /// @dev For adding more tokens that are loanable on the platform
    /// @param _token the address of the token you want to be loanable on the protocol
    /// @param _priceFeed the address of the currency pair on chainlink
    function addLoanableToken(address _token, address _priceFeed) external {
        LibDiamond.enforceIsContractOwner();
        _appStorage.s_isLoanable[_token] = true;
        _appStorage.s_priceFeeds[_token] = _priceFeed;
        _appStorage.s_loanableToken.push(_token);
        emit UpdateLoanableToken(_token, _priceFeed, msg.sender);
    }

    /// @dev for upating git coin post score
    /// @param _user the address to the user you want to update
    /// @param _score the gitcoin point score.
    function updateGPScore(address _user, uint256 _score) public {
        LibDiamond.enforceIsContractOwner();
        _appStorage.addressToUser[_user].gitCoinPoint = _score;
    }

    /**
     * @notice Allows a user to withdraw the deposited ads token for a specific order
     * @dev Withdraws the ads token associated with an open order, closes the order, and emits an event
     * @param _listingId The ID of the order to withdraw the token from
     */
    function closeListingAd(uint96 _listingId) external {
        LoanListing storage _newListing = _appStorage.loanListings[_listingId];
        if (_newListing.listingStatus != ListingStatus.OPEN)
            revert Protocol__OrderNotOpen();
        if (_newListing.author != msg.sender)
            revert Protocol__OwnerCreatedOrder();
        if (_newListing.amount == 0) revert Protocol__MustBeMoreThanZero();

        uint256 _amount = _newListing.amount;
        _newListing.amount = 0;
        _newListing.listingStatus = ListingStatus.CLOSED;

        if (_newListing.tokenAddress == Constants.NATIVE_TOKEN) {
            (bool sent, ) = payable(msg.sender).call{value: _amount}("");
            require(sent, "Protocol__TransferFailed");
        } else {
            bool success = IERC20(_newListing.tokenAddress).transfer(
                msg.sender,
                _amount
            );
            require(success, "Protocol__TransferFailed");
        }

        emit withdrawnAdsToken(
            msg.sender,
            _listingId,
            uint8(_newListing.listingStatus),
            _amount
        );
    }

    function closeRequest(uint96 _requestId) external {
        Request storage _foundRequest = _appStorage.request[_requestId];
        Request storage _Request = _appStorage.s_requests[_requestId - 1];

        if (_foundRequest.status != Status.OPEN)
            revert Protocol__RequestNotOpen();
        if (_foundRequest.author != msg.sender) revert Protocol__NotOwner();

        _foundRequest.status = Status.CLOSED;
        _Request.status = Status.CLOSED;
    }

    /**
     * @notice Allows a user to create loan listing ads for a specific token with borrow limit
     * @dev creates a listing, transfers token from user to protocol, and emits an event
     * @param _amount The total amount of the loan to be listed
     * @param _min_amount The minimum amount that can be borrowed from the listing
     * @param _max_amount The maximum amount that can be borrowed from the listing
     * @param _returnDate The total number of days the loan must be returned
     * @param _interest The interest rate to be applied to the loan
     * @param _loanCurrency The token address for the loan currency
     */
    function createLoanListing(
        uint256 _amount,
        uint256 _min_amount,
        uint256 _max_amount,
        uint256 _returnDate,
        uint16 _interest,
        address _loanCurrency
    )
        external
        payable
        _valueMoreThanZero(_amount, _loanCurrency)
        _moreThanZero(_amount)
    {
        if (!_appStorage.s_isLoanable[_loanCurrency]) {
            revert Protocol__TokenNotLoanable();
        }

        if (_loanCurrency != Constants.NATIVE_TOKEN) {
            if (IERC20(_loanCurrency).balanceOf(msg.sender) < _amount)
                revert Protocol__InsufficientBalance();

            if (
                IERC20(_loanCurrency).allowance(msg.sender, address(this)) <
                _amount
            ) revert Protocol__InsufficientAllowance();
        }

        if (_loanCurrency == Constants.NATIVE_TOKEN) {
            _amount = msg.value;
        }

        if (_loanCurrency != Constants.NATIVE_TOKEN) {
            bool _success = IERC20(_loanCurrency).transferFrom(
                msg.sender,
                address(this),
                _amount
            );
            if (!_success) {
                revert Protocol__TransferFailed();
            }
        }

        _appStorage.listingId = _appStorage.listingId + 1;
        LoanListing storage _newListing = _appStorage.loanListings[
            _appStorage.listingId
        ];
        _newListing.listingId = _appStorage.listingId;
        _newListing.author = msg.sender;
        _newListing.amount = _amount;
        _newListing.min_amount = _min_amount;
        _newListing.max_amount = _max_amount;
        _newListing.interest = _interest;
        _newListing.returnDate = _returnDate;
        _newListing.tokenAddress = _loanCurrency;
        _newListing.listingStatus = ListingStatus.OPEN;
        // _appStorage.loanListings[_appStorage.listingId] = _newListing;

        emit LoanListingCreated(
            _appStorage.listingId,
            msg.sender,
            _loanCurrency,
            _amount
        );
    }

    /**
     * @notice Allows a user to request a loan from a listing ad
     * @dev creates a request from the listing, transfers token from protocol to user and emits an event
     * @param _listingId The id of the listing to request a loan from
     * @param _amount The amount that should be borrowed from the listing
     */
    function requestLoanFromListing(
        uint96 _listingId,
        uint256 _amount
    ) public _moreThanZero(_amount) {
        LoanListing storage _listing = _appStorage.loanListings[_listingId];
        if (_listing.listingStatus != ListingStatus.OPEN)
            revert Protocol__ListingNotOpen();

        if (_listing.author == msg.sender)
            revert Protocol__OwnerCreatedListing();

        if ((_amount < _listing.min_amount) || (_amount > _listing.max_amount))
            revert Protocol__InvalidAmount();
        if (_amount > _listing.amount) revert Protocol__InvalidAmount();

        uint8 _decimalToken = _getTokenDecimal(_listing.tokenAddress);
        uint256 _loanUsdValue = getUsdValue(
            _listing.tokenAddress,
            _amount,
            _decimalToken
        );

        if (_healthFactor(msg.sender, _loanUsdValue) < 1) {
            revert Protocol__InsufficientCollateral();
        }

        uint256 collateralValueInLoanCurrency = getAccountCollateralValue(
            msg.sender
        );
        uint256 maxLoanableAmount = (collateralValueInLoanCurrency *
            Constants.COLLATERALIZATION_RATIO) / 100;

        _listing.amount = _listing.amount - _amount;

        if (_listing.amount <= _listing.max_amount) {
            _listing.max_amount = _listing.amount;
        }

        if (_listing.amount <= _listing.min_amount) {
            _listing.min_amount = 0;
        }

        address[] memory _collateralTokens = getUserCollateralTokens(
            msg.sender
        );

        _appStorage.requestId = _appStorage.requestId + 1;
        Request storage _newRequest = _appStorage.request[
            _appStorage.requestId
        ];
        _newRequest.requestId = _appStorage.requestId;
        _newRequest.author = msg.sender;
        _newRequest.lender = _listing.author;
        _newRequest.amount = _amount;
        _newRequest.interest = _listing.interest;
        _newRequest.returnDate = _listing.returnDate;
        _newRequest.totalRepayment = _calculateLoanInterest(
            _listing.returnDate,
            _amount,
            _listing.interest
        );
        _newRequest.loanRequestAddr = _listing.tokenAddress;
        _newRequest.collateralTokens = _collateralTokens;
        _newRequest.status = Status.SERVICED;

        uint256 collateralToLock = (_loanUsdValue * 100 * Constants.PRECISION) /
            maxLoanableAmount;

        for (uint256 i = 0; i < _collateralTokens.length; i++) {
            address token = _collateralTokens[i];
            uint8 decimal = _getTokenDecimal(token);
            uint256 userBalance = _appStorage.s_addressToCollateralDeposited[
                msg.sender
            ][token];

            // Calculate the amount to lock for each token based on its proportion of the total collateral
            uint256 amountToLockUSD = (getUsdValue(
                token,
                userBalance,
                decimal
            ) * collateralToLock) / 100;
            uint256 amountToLock = ((((amountToLockUSD) * 10) /
                getUsdValue(token, 10, 0)) * (10 ** _decimalToken)) /
                Constants.PRECISION;

            _appStorage.s_idToCollateralTokenAmount[_appStorage.requestId][
                token
            ] = amountToLock;
            _appStorage.s_addressToAvailableBalance[msg.sender][
                token
            ] -= amountToLock;
        }

        _appStorage.s_requests.push(_newRequest);
        _appStorage
            .addressToUser[msg.sender]
            .totalLoanCollected += _loanUsdValue;

        if (_listing.tokenAddress == Constants.NATIVE_TOKEN) {
            (bool sent, ) = payable(msg.sender).call{value: _amount}("");
            require(sent, "Protocol__TransferFailed");
        } else {
            bool success = IERC20(_listing.tokenAddress).transfer(
                msg.sender,
                _amount
            );
            require(success, "Protocol__TransferFailed");
        }

        emit RequestCreated(
            msg.sender,
            _appStorage.requestId,
            _amount,
            _listing.interest
        );

        emit RequestServiced(
            _newRequest.requestId,
            _newRequest.lender,
            _newRequest.author,
            _amount
        );
    }

    function repayLoan(uint96 _requestId, uint256 _amount) external payable {
        require(_amount > 0, "Protocol__MustBeMoreThanZero");
        Request storage _request = _appStorage.request[_requestId];
        Request storage _foundRequest = _appStorage.s_requests[_requestId - 1];

        if (_request.status != Status.SERVICED)
            revert Protocol__RequestNotServiced();

        if (msg.sender != _request.author) revert Protocol__NotOwner();

        if (_request.loanRequestAddr == Constants.NATIVE_TOKEN) {
            _amount = msg.value;
        } else {
            IERC20 _token = IERC20(_request.loanRequestAddr);
            if (_token.balanceOf(msg.sender) < _amount) {
                revert Protocol__InsufficientBalance();
            }
            if (_token.allowance(msg.sender, address(this)) < _amount)
                revert Protocol__InsufficientAllowance();

            _token.transferFrom(msg.sender, address(this), _amount);
        }

        if (_amount >= _request.totalRepayment) {
            _amount = _request.totalRepayment;
            _request.totalRepayment = 0;
            _foundRequest.totalRepayment = 0;
            _request.status = Status.CLOSED;
            _foundRequest.status = Status.CLOSED;
        } else {
            _request.totalRepayment -= _amount;
            _foundRequest.totalRepayment -= _amount;
        }

        uint8 decimal = _getTokenDecimal(_request.loanRequestAddr);
        uint256 _loanUsdValue = getUsdValue(
            _request.loanRequestAddr,
            _amount,
            decimal
        );
        uint256 loanCollected = getLoanCollectedInUsd(msg.sender);

        _appStorage.s_addressToCollateralDeposited[_request.lender][
            _request.loanRequestAddr
        ] += _amount;
        _appStorage.s_addressToAvailableBalance[_request.lender][
            _request.loanRequestAddr
        ] += _amount;

        for (uint i = 0; i < _request.collateralTokens.length; i++) {
            _appStorage.s_addressToAvailableBalance[_request.author][
                _request.collateralTokens[i]
            ] += _appStorage.s_idToCollateralTokenAmount[_requestId][
                _request.collateralTokens[i]
            ];
        }
        if (loanCollected > _loanUsdValue) {
            _appStorage.addressToUser[msg.sender].totalLoanCollected =
                loanCollected -
                _loanUsdValue;
        } else {
            _appStorage.addressToUser[msg.sender].totalLoanCollected = 0;
        }

        emit LoanRepayment(msg.sender, _requestId, _amount);
    }



    function liquidateUserRequest(uint96 requestId)
        external
        onlyBot(requestId)
    {
        Request memory _activeRequest = 
        getActiveRequestsByRequestId(requestId);

        
        address loanCurrency = _activeRequest.loanRequestAddr;
        address lenderAddress = _activeRequest.lender;
        uint256 swappedAmount = 0;
        
        for (uint96 index = 0; index < _activeRequest.collateralTokens.length; index++) {
            address collateralToken = _activeRequest.collateralTokens[index];
            uint256 amountOfCollateralToken =
            _appStorage.s_idToCollateralTokenAmount[requestId][collateralToken];
            
            if (amountOfCollateralToken > 0) {
               

                uint256 [] memory loanCurrencyAmount = 
                swapToLoanCurrency(collateralToken, amountOfCollateralToken, loanCurrency);

                _appStorage.s_addressToCollateralDeposited[
                    _activeRequest.author][collateralToken] -= amountOfCollateralToken;

                if(loanCurrencyAmount.length > 0) {

                    swappedAmount += loanCurrencyAmount[1];
                }else{
                    swappedAmount += amountOfCollateralToken;
                }

                _appStorage.s_idToCollateralTokenAmount[requestId][collateralToken] = 0;
            }
        }

        // Transfer total repayment to lender
        IERC20(loanCurrency).transfer(lenderAddress, _activeRequest.totalRepayment);
        
        _activeRequest.status = Status.CLOSED;

        emit RequestLiquidated(
            requestId,
            lenderAddress,
            _activeRequest.totalRepayment
        );
    }



function swapToLoanCurrency(
    address collateralToken,
    uint256 collateralAmount,
    address loanCurrency
) public returns (uint256[] memory loanCurrencyAmount) {
    
 

    uint256 amountOfTokenOut_ = getConvertValue(collateralToken, loanCurrency, collateralAmount);
    uint[] memory amountsOut;

    if(loanCurrency == collateralToken) {
        return amountsOut;
    } 

     if (collateralToken == Constants.NATIVE_TOKEN) {
         // Wrap ETH to WETH by depositing it
        collateralToken = Constants.WETH;
        }

        address[] memory path = new address[](2); 
        path[0] = collateralToken;
        path[1] = loanCurrency;

    // If collateralToken is ETH, use swapExactETHForTokens



    if (collateralToken == Constants.WETH) {
        amountsOut = IUniswapV2Router02(_appStorage.swapRouter).swapExactETHForTokens{value: collateralAmount}(
            amountOfTokenOut_,
            path,
            address(this),
            block.timestamp + 300
        );

    // If loanCurrency is ETH, use swapTokensForExactETH
    } else if (loanCurrency == Constants.WETH) {

        // Approve Uniswap to spend collateral tokens
        IERC20(collateralToken).approve(_appStorage.swapRouter, collateralAmount);

        path[0] = loanCurrency;
        path[1] = collateralToken;

        amountsOut = IUniswapV2Router02(_appStorage.swapRouter).swapExactTokensForETH(
            collateralAmount,
            amountOfTokenOut_,
            path,
            address(this),
            block.timestamp + 300
        );

    // For ERC20 to ERC20 swaps, use swapExactTokensForTokens
    }else {
        // Approve Uniswap to spend collateral tokens
        IERC20(collateralToken).approve(_appStorage.swapRouter, collateralAmount);

        amountsOut = IUniswapV2Router02(_appStorage.swapRouter).swapExactTokensForTokens(
            collateralAmount,
            amountOfTokenOut_,
            path,
            address(this),
            block.timestamp + 300
        );
    }
    
    return amountsOut; // Return the amount of loan currency received
}


    function getActiveRequestsByRequestId(
        uint96 _requestId
    ) private view returns (Request memory) {
        Request memory _request = _appStorage.request[_requestId];
        if (_request.status != Status.SERVICED) {
            revert Protocol__RequestNotServiced();
        }
        return _request;
    }

    function setBotAddress(address _botAddress) external {
        LibDiamond.enforceIsContractOwner();
        _appStorage.botAddress = _botAddress;
    }

    function setSwapRouter(address _swapRouter) external {
        LibDiamond.enforceIsContractOwner();
        _appStorage.swapRouter = _swapRouter;
    }

    ///////////////////////
    /// VIEW FUNCTIONS ///
    //////////////////////

    /// @notice This gets the USD value of amount of the token passsed.
    /// @dev This uses chainlinks AggregatorV3Interface to get the price with the pricefeed address.
    /// @param _token a collateral token address that is allowed in our Smart Contract
    /// @param _amount the amount of that token you want to get the USD equivalent of.
    /// @return uint256 returns the equivalent amount in USD.
    function getUsdValue(
        address _token,
        uint256 _amount,
        uint8 _decimal
    ) public view returns (uint256) {
        AggregatorV3Interface _priceFeed = AggregatorV3Interface(
            _appStorage.s_priceFeeds[_token]
        );
        (, int256 _price, , , ) = _priceFeed.latestRoundData();
        return
            ((uint256(_price) * Constants.NEW_PRECISION) * (_amount)) /
            (Constants.PRECISION * (10 ** _decimal));
    }

    ///@notice get the expected amount in converting tokens
    function getConvertValue(
        address _from,
        address _to,
        uint256 _amount
    ) public view returns (uint256 value) {
        uint8 fromDecimal = _getTokenDecimal(_from);
        uint8 toDecimal = _getTokenDecimal(_to);
        uint256 fromUsd = getUsdValue(_from, _amount, fromDecimal);
        value = ((fromUsd * 10) / getUsdValue(_to, 10, 0)) * (10 ** toDecimal);
    }

    /// @notice This gets the amount of collateral a user has deposited in USD
    /// @param _user the address who you want to get their collateral value
    /// @return _totalCollateralValueInUsd returns the value of the user deposited collateral in USD
    function getAccountCollateralValue(
        address _user
    ) public view returns (uint256 _totalCollateralValueInUsd) {
        for (
            uint256 index = 0;
            index < _appStorage.s_collateralToken.length;
            index++
        ) {
            address _token = _appStorage.s_collateralToken[index];
            uint256 _amount = _appStorage.s_addressToCollateralDeposited[_user][
                _token
            ];
            uint8 _tokenDecimal = _getTokenDecimal(_token);
            _totalCollateralValueInUsd += getUsdValue(
                _token,
                _amount,
                _tokenDecimal
            );
        }
    }

    function getAccountAvailableValue(
        address _user
    ) public view returns (uint256 _totalAvailableValueInUsd) {
        for (
            uint256 index = 0;
            index < _appStorage.s_collateralToken.length;
            index++
        ) {
            address _token = _appStorage.s_collateralToken[index];
            uint256 _amount = _appStorage.s_addressToAvailableBalance[_user][
                _token
            ];
            uint8 _tokenDecimal = _getTokenDecimal(_token);
            _totalAvailableValueInUsd += getUsdValue(
                _token,
                _amount,
                _tokenDecimal
            );
        }
    }

    /**
     * @notice Retrieves all the requests stored in the system
     * @dev Returns an array of all requests
     * @return An array of `Request` structs representing all stored requests
     */
    function getAllRequest() external view returns (Request[] memory) {
        return _appStorage.s_requests;
    }

    /**
     * @notice Retrieves the details of a specific loan listing by its ID
     * @dev Returns the listing if it exists, otherwise reverts if the listing's author is the zero address
     * @param _listingId The ID of the listing to retrieve
     * @return The `LoanListing` struct containing details of the specified listing
     */
    function getLoanListing(
        uint96 _listingId
    ) external view returns (LoanListing memory) {
        LoanListing memory _listing = _appStorage.loanListings[_listingId];
        if (_listing.author == address(0)) revert Protocol__IdNotExist();
        return _listing;
    }

    /**
     * @notice Retrieves the details of a specific request by its ID
     * @dev Returns the request if it exists, otherwise reverts if the request's author is the zero address
     * @param _requestId The ID of the request to retrieve
     * @return The `Request` struct containing details of the specified request
     */
    function getRequest(
        uint96 _requestId
    ) external view returns (Request memory) {
        Request memory _request = _appStorage.request[_requestId];
        if (_request.author == address(0)) revert Protocol__NotOwner();
        return _request;
    }

    /// @notice This gets the account info of any account
    /// @param _user a parameter for the user account info you want to get
    /// @return _totalBurrowInUsd returns the total amount of SC the  user has minted
    /// @return _collateralValueInUsd returns the total collateral the user has deposited in USD
    function _getAccountInfo(
        address _user
    )
        private
        view
        returns (uint256 _totalBurrowInUsd, uint256 _collateralValueInUsd)
    {
        _totalBurrowInUsd = getLoanCollectedInUsd(_user);
        _collateralValueInUsd = getAccountCollateralValue(_user);
    }

    /// @notice Checks the health Factor which is a way to check if the user has enough collateral
    /// @param _user a parameter for the address to check
    /// @return uint256 returns the health factor which is supoose to be >= 1
    function getHealthFactor(address _user) external view returns (uint256) {
        return _healthFactor(_user, 0);
    }

    /// @notice Checks the health Factor which is a way to check if the user has enough collateral to mint
    /// @param _user a parameter for the address to check
    /// @param _borrow_Value amount the user wants to borrow in usd
    /// @return uint256 returns the health factor which is supoose to be >= 1
    function _healthFactor(
        address _user,
        uint256 _borrow_Value
    ) private view returns (uint256) {
        (
            uint256 _totalBurrowInUsd,
            uint256 _collateralValueInUsd
        ) = _getAccountInfo(_user);
        uint256 _collateralAdjustedForThreshold = (_collateralValueInUsd *
            Constants.LIQUIDATION_THRESHOLD) / 100;

        if ((_totalBurrowInUsd == 0) && (_borrow_Value == 0))
            return (_collateralAdjustedForThreshold * Constants.PRECISION);

        return
            (_collateralAdjustedForThreshold * Constants.PRECISION) /
            (_totalBurrowInUsd + _borrow_Value);
    }

    function _getTokenDecimal(
        address _token
    ) internal view returns (uint8 decimal) {
        if (_token == Constants.NATIVE_TOKEN) {
            decimal = 18;
        } else {
            decimal = ERC20(_token).decimals();
        }
    }

    /// @dev get the collection of all collateral token
    /// @return {address[] memory} the collection of collateral addresses
    function getAllCollateralToken() external view returns (address[] memory) {
        return _appStorage.s_collateralToken;
    }

    /// @notice This checks the health factor to see if  it is broken if it is it reverts
    /// @param _user a parameter for the address we want to check the health factor for
    function _revertIfHealthFactorIsBroken(address _user) internal view {
        uint256 _userHealthFactor = _healthFactor(_user, 0);
        if (_userHealthFactor < Constants.MIN_HEALTH_FACTOR) {
            revert Protocol__BreaksHealthFactor();
        }
    }

    /// @dev gets the amount of collateral auser has deposited
    /// @param _sender the user who has the collateral
    /// @param _tokenAddr the user who has the collateral
    /// @return {uint256} the return variables of a contract’s function state variable
    function gets_addressToCollateralDeposited(
        address _sender,
        address _tokenAddr
    ) external view returns (uint256) {
        return _appStorage.s_addressToCollateralDeposited[_sender][_tokenAddr];
    }

    /// @dev gets the amount of token balance avialble to the user
    /// @param _sender the user who has the balance
    /// @param _tokenAddr the user who has the balance
    /// @return {uint256} the return variables of a contract’s function state variable
    function gets_addressToAvailableBalance(
        address _sender,
        address _tokenAddr
    ) external view returns (uint256) {
        return _appStorage.s_addressToAvailableBalance[_sender][_tokenAddr];
    }

    function getRequestToColateral(
        uint96 _requestId,
        address _token
    ) external view returns (uint256) {
        return _appStorage.s_idToCollateralTokenAmount[_requestId][_token];
    }

    /// @dev calculates the loan interest and add it to the loam
    /// @param _returnDate the date at which the loan should be returned
    /// @param _amount the amount the user want to borrow
    /// @param _interest the percentage the user has agreed to payback
    /// @return _totalRepayment the amount the user is to payback
    function _calculateLoanInterest(
        uint256 _returnDate,
        uint256 _amount,
        uint16 _interest
    ) internal view returns (uint256 _totalRepayment) {
        if (_returnDate < block.timestamp)
            revert Protocol__DateMustBeInFuture();
        // Calculate the total repayment amount including interest
        _totalRepayment =
            _amount +
            Utils.calculatePercentage(_amount, _interest);
        return _totalRepayment;
    }

    /// @dev for getting the gitcoinpoint score
    /// @param _user the address of you wan to check the score for.
    /// @return _score the user scors.
    function get_gitCoinPoint(
        address _user
    ) external view returns (uint256 _score) {
        LibDiamond.enforceIsContractOwner();
        _score = _appStorage.addressToUser[_user].gitCoinPoint;
    }

    /// @return _assets the collection of token that can be loaned in the protocol
    function getLoanableAssets()
        external
        view
        returns (address[] memory _assets)
    {
        _assets = _appStorage.s_loanableToken;
    }

    /// @dev gets a request from a user
    /// @param _user the addresss of the user
    /// @param _requestId the id of the request that was created by the user
    /// @return Documents the return variables of a contract’s function state variable
    function getUserRequest(
        address _user,
        uint96 _requestId
    ) external view returns (Request memory) {
        Request memory _request = _appStorage.request[_requestId];
        if (_request.author != _user) revert Protocol__NotOwner();
        return _request;
    }

    function getUserActiveRequests(
        address _user
    ) public view returns (Request[] memory _requests) {
        Request[] memory requests = _appStorage.s_requests;
        uint64 requestLength;
        for (uint i = 0; i < requests.length; i++) {
            if (
                requests[i].author == _user &&
                requests[i].status == Status.SERVICED
            ) {
                requestLength++;
            }
        }

        _requests = new Request[](requestLength);

        for (uint i = 0; i < requests.length; i++) {
            if (
                requests[i].author == _user &&
                requests[i].status == Status.SERVICED
            ) {
                _requests[requestLength - 1] = requests[i];
                requestLength--;
            }
        }
    }

    function getServicedRequestByLender(
        address _lender
    ) public view returns (Request[] memory _requests) {
        Request[] memory requests = _appStorage.s_requests;
        uint64 requestLength;
        for (uint i = 0; i < requests.length; i++) {
            if (requests[i].lender == _lender) {
                requestLength++;
            }
        }

        _requests = new Request[](requestLength);

        for (uint i = 0; i < requests.length; i++) {
            if (requests[i].lender == _lender) {
                _requests[requestLength - 1] = requests[i];
                requestLength--;
            }
        }
    }

    function getLoanCollectedInUsd(
        address _user
    ) public view returns (uint256 _value) {
        Request[] memory userActiveRequest = getUserActiveRequests(_user);
        uint256 loans = 0;
        for (uint i = 0; i < userActiveRequest.length; i++) {
            uint8 tokenDecimal = _getTokenDecimal(
                userActiveRequest[i].loanRequestAddr
            );
            loans += getUsdValue(
                userActiveRequest[i].loanRequestAddr,
                userActiveRequest[i].amount,
                tokenDecimal
            );
        }
        _value = loans;
    }

    function getUserCollateralTokens(
        address _user
    ) public view returns (address[] memory _collaterals) {
        address[] memory tokens = _appStorage.s_collateralToken;
        uint8 userLength = 0;

        for (uint256 i = 0; i < tokens.length; i++) {
            if (_appStorage.s_addressToAvailableBalance[_user][tokens[i]] > 0) {
                userLength++;
            }
        }

        address[] memory userTokens = new address[](userLength);

        for (uint256 i = 0; i < tokens.length; i++) {
            if (
                _appStorage.s_addressToCollateralDeposited[_user][tokens[i]] > 0
            ) {
                userTokens[userLength - 1] = tokens[i];
                userLength--;
            }
        }

        return userTokens;
    }
    fallback() external {
        revert("ProtocolFacet: fallback");
    }
}
