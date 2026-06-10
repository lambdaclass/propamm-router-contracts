//! Public ABI of `PropAMMRouter` (src/PropAMMRouter.sol). Self-call-only
//! internals (`_dispatchVenue`, `_dispatchQuoteVenue`) and UUPS plumbing are
//! intentionally omitted. Verified against `forge inspect PropAMMRouter abi`.

// The swap entrypoints mirror the contract's parameter lists.
#![allow(clippy::too_many_arguments)]

use alloy_sol_types::sol;

sol! {
    #[derive(Debug)]
    interface IPropAMMRouter {
        struct FrontendFee {
            uint16 bps;
            address recipient;
        }

        // Swaps
        function swapV1(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, address recipient, uint256 deadline) external payable returns (uint256 amountOut, address executedVenue);
        function swapWithFeeV1(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, address recipient, uint256 deadline, FrontendFee fee) external payable returns (uint256 amountOut, address executedVenue);
        function swapViaVenueV1(address venue, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, address recipient, uint256 deadline) external payable returns (uint256 amountOut, address executedVenue);
        function swapViaVenueWithFeeV1(address venue, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, address recipient, uint256 deadline, FrontendFee fee) external payable returns (uint256 amountOut);
        function swapViaSelectedVenuesV1(address[] venues, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, address recipient, uint256 deadline) external payable returns (uint256 amountOut, address executedVenue);
        function swapViaSelectedVenuesWithFeeV1(address[] venues, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, address recipient, uint256 deadline, FrontendFee fee) external payable returns (uint256 amountOut, address executedVenue);

        // Quotes — nonpayable (not view) on-chain; call off-chain via simulation
        function quoteV1(address tokenIn, address tokenOut, uint256 amount) external returns (uint256 bestQuote, address venue);
        function quoteVenueV1(address venue, address tokenIn, address tokenOut, uint256 amount) external returns (uint256 amountOut, address quotedVenue);
        function quoteSelectedVenuesV1(address[] venues, address tokenIn, address tokenOut, uint256 amountIn) external returns (uint256 bestAmountOut, address bestVenue);
        function quoteUniswapV3(address tokenIn, address tokenOut, uint256 amount) external returns (uint256 amountOut);

        // Views
        function fallbackSwapRouter() external view returns (address);
        function fallbackQuoter() external view returns (address);
        function fallbackFee() external view returns (uint24);
        function getPairFee(address tokenA, address tokenB) external view returns (uint24);
        function resolvedFee(address tokenIn, address tokenOut) external view returns (uint24);
        function isWhitelistedVenue(address venue) external view returns (bool);
        function getWhitelistedVenues() external view returns (address[]);
        function whitelistedVenueCount() external view returns (uint256);
        function whitelistedVenueAt(uint256 index) external view returns (address);
        function paused() external view returns (bool);
        function authority() external view returns (address);

        // Administration (access-controlled via the AccessManager authority).
        // No typed bindings — call through the generated instance directly.
        function setFallbackSwapRouter(address newRouter) external;
        function setFallbackQuoter(address newQuoter) external;
        function setFallbackFee(uint24 fee) external;
        function setPairFee(address tokenA, address tokenB, uint24 fee) external;
        function setPairFees(address[] tokenA, address[] tokenB, uint24[] fees) external;
        function addVenue(address venue) external;
        function removeVenue(address venue) external;
        function pause() external;
        function unpause() external;
        function rescueTokens(address token, address to, uint256 amount) external;

        // Events
        event Swapped(address indexed sender, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut, address recipient, address marketMaker);
        event FrontendFeeCharged(address indexed feeRecipient, address indexed tokenOut, uint256 feeAmount, address indexed payer);
        event FallbackFeeUpdated(uint24 oldFee, uint24 newFee);
        event FallbackSwapRouterUpdated(address indexed oldRouter, address indexed newRouter);
        event FallbackQuoterUpdated(address indexed oldQuoter, address indexed newQuoter);
        event PairFeeUpdated(address indexed tokenA, address indexed tokenB, uint24 oldFee, uint24 newFee);
        event TokensRescued(address indexed token, address indexed to, uint256 amount);
        event VenueWhitelisted(address indexed venue);
        event VenueRemoved(address indexed venue);

        // Errors — included so reverts decode into named errors
        error OnlySelf();
        error UnknownVenue();
        error InsufficientOutput(uint256 expectedAmount, uint256 receivedAmount);
        error Expired();
        error NoQuotesAvailable();
        error TokenOutBalanceDecreased();
        error InvalidFallbackFee(uint24 fee);
        error ZeroAddress();
        error ArrayLengthMismatch();
        error VenueAlreadyWhitelisted(address venue);
        error VenueNotWhitelisted(address venue);
        error InvalidValue(uint256 expected, uint256 received);
        error ETHTransferFailed();
        error UnexpectedETHSender();
        error IdenticalTokens();
        error FeeBpsTooHigh(uint16 requested, uint16 max);
        // From OpenZeppelin Pausable — what swaps revert with while paused.
        error EnforcedPause();
    }

    interface IERC20 {
        function approve(address spender, uint256 amount) external returns (bool);
        function allowance(address owner, address spender) external view returns (uint256);
    }
}
