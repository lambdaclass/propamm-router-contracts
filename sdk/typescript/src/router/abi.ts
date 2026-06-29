import { parseAbi } from "viem";

/**
 * Public ABI of `PropAMMRouter` (src/PropAMMRouter.sol), kept as
 * human-readable signatures so viem can fully infer argument and return
 * types. The self-call-only internal (`_dispatchVenue`) and UUPS plumbing
 * are intentionally omitted.
 */
export const propAmmRouterAbi = parseAbi([
  "struct FrontendFee { uint16 bps; address recipient; }",

  // Swaps
  "function swapV1(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, address recipient, uint256 deadline) payable returns (uint256 amountOut, address executedVenue)",
  "function swapWithFeeV1(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, address recipient, uint256 deadline, FrontendFee fee) payable returns (uint256 amountOut, address executedVenue)",
  "function swapViaVenueV1(address venue, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, address recipient, uint256 deadline) payable returns (uint256 amountOut, address executedVenue)",
  "function swapViaVenueWithFeeV1(address venue, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, address recipient, uint256 deadline, FrontendFee fee) payable returns (uint256 amountOut)",
  "function swapViaSelectedVenuesV1(address[] venues, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, address recipient, uint256 deadline) payable returns (uint256 amountOut, address executedVenue)",
  "function swapViaSelectedVenuesWithFeeV1(address[] venues, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, address recipient, uint256 deadline, FrontendFee fee) payable returns (uint256 amountOut, address executedVenue)",

  // Quotes — nonpayable (not view) on-chain; call off-chain via simulation
  "function quoteV1(address tokenIn, address tokenOut, uint256 amount) returns (uint256 bestQuote, address venue)",
  "function quoteVenueV1(address venue, address tokenIn, address tokenOut, uint256 amount) returns (uint256 amountOut, address quotedVenue)",
  "function quoteSelectedVenuesV1(address[] venues, address tokenIn, address tokenOut, uint256 amountIn) returns (uint256 bestAmountOut, address bestVenue)",

  // Views
  "function fallbackQuoter() view returns (address)",
  "function fallbackFee() view returns (uint24)",
  "function getPairFee(address tokenA, address tokenB) view returns (uint24)",
  "function resolvedFee(address tokenIn, address tokenOut) view returns (uint24)",
  "function isWhitelistedVenue(address venue) view returns (bool)",
  "function getWhitelistedVenues() view returns (address[])",
  "function whitelistedVenueCount() view returns (uint256)",
  "function whitelistedVenueAt(uint256 index) view returns (address)",
  "function paused() view returns (bool)",
  "function authority() view returns (address)",

  // Administration (access-controlled via the AccessManager authority).
  // No typed bindings — call through `ContractClient.write` with this ABI.
  "function setFallbackQuoter(address newQuoter)",
  "function setFallbackFee(uint24 fee)",
  "function setPairFee(address tokenA, address tokenB, uint24 fee)",
  "function setPairFees(address[] tokenA, address[] tokenB, uint24[] fees)",
  "function addVenue(address venue)",
  "function removeVenue(address venue)",
  "function pause()",
  "function unpause()",
  "function rescueTokens(address token, address to, uint256 amount)",

  // Events
  "event Swapped(address indexed sender, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut, address recipient, address marketMaker)",
  "event FrontendFeeCharged(address indexed feeRecipient, address indexed tokenOut, uint256 feeAmount, address indexed payer)",
  "event FallbackFeeUpdated(uint24 oldFee, uint24 newFee)",
  "event FallbackQuoterUpdated(address indexed oldQuoter, address indexed newQuoter)",
  "event PairFeeUpdated(address indexed tokenA, address indexed tokenB, uint24 oldFee, uint24 newFee)",
  "event TokensRescued(address indexed token, address indexed to, uint256 amount)",
  "event VenueWhitelisted(address indexed venue)",
  "event VenueRemoved(address indexed venue)",

  // Errors — included so viem decodes reverts into named errors
  "error OnlySelf()",
  "error UnknownVenue()",
  "error InsufficientOutput(uint256 expectedAmount, uint256 receivedAmount)",
  "error Expired()",
  "error NoQuotesAvailable()",
  "error TokenOutBalanceDecreased()",
  "error InvalidFallbackFee(uint24 fee)",
  "error ZeroAddress()",
  "error ArrayLengthMismatch()",
  "error VenueAlreadyWhitelisted(address venue)",
  "error VenueNotWhitelisted(address venue)",
  "error InvalidValue(uint256 expected, uint256 received)",
  "error ETHTransferFailed()",
  "error UnexpectedETHSender()",
  "error IdenticalTokens()",
  "error OnlyPool()",
  "error ExcessiveInput()",
  "error FeeBpsTooHigh(uint16 requested, uint16 max)",
  // From OpenZeppelin Pausable — what swaps revert with while paused.
  "error EnforcedPause()",
]);
