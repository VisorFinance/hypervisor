// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.7.6;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/math/SignedSafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/drafts/ERC20Permit.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";

import "./interfaces/IVault.sol";
import "./interfaces/IUniversalVault.sol";

/// @title Hypervisor
/// @notice A Uniswap V2-like interface with fungible liquidity to Uniswap V3
/// which allows for arbitrary liquidity provision: one-sided, lop-sided, and balanced
contract Hypervisor is IVault, IUniswapV3MintCallback, IUniswapV3SwapCallback, ERC20Permit, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    using SignedSafeMath for int256;

    IUniswapV3Pool public pool;
    IERC20 public token0;
    IERC20 public token1;
    uint24 public fee;
    int24 public tickSpacing;

    int24 public baseLower;
    int24 public baseUpper;
    int24 public limitLower;
    int24 public limitUpper;

    address public owner;
    uint256 public deposit0Max;
    uint256 public deposit1Max;
    uint256 public maxTotalSupply;
    mapping(address => bool) public list; /// whitelist of depositors
    bool public whitelisted; /// depositors must be on list
    bool public directDeposit; /// enter uni on deposit (avoid if client uses public rpc)

    uint256 public constant PRECISION = 1e36;

    bool rebalanceCalled;
    bool mintCalled;

    /// events
    event MaxTotalSupplySet(uint256 _maxTotalSupply);
    event DepositMaxSet(uint256 _deposit0Max, uint256 _deposit1Max);

    /// @param _pool Uniswap V3 pool for which liquidity is managed
    /// @param _owner Owner of the Hypervisor
    constructor(
        address _pool,
        address _owner,
        string memory name,
        string memory symbol
    ) ERC20Permit(name) ERC20(name, symbol) {
        require(_pool != address(0));
        require(_owner != address(0));
        pool = IUniswapV3Pool(_pool);
        token0 = IERC20(pool.token0());
        token1 = IERC20(pool.token1());
        require(address(token0) != address(0));
        require(address(token1) != address(0));
        fee = pool.fee();
        tickSpacing = pool.tickSpacing();

        owner = _owner;

        maxTotalSupply = 0; /// no cap
        deposit0Max = uint256(-1);
        deposit1Max = uint256(-1);
        whitelisted = false;
    }

    /// @notice Deposit tokens
    /// @param deposit0 Amount of token0 transfered from sender to Hypervisor
    /// @param deposit1 Amount of token1 transfered from sender to Hypervisor
    /// @param to Address to which liquidity tokens are minted
    /// @param from Address from which asset tokens are transferred
    /// @return shares Quantity of liquidity tokens minted as a result of deposit
    function deposit(
        uint256 deposit0,
        uint256 deposit1,
        address to,
        address from
    ) external override returns (uint256 shares) {
        require(deposit0 > 0 || deposit1 > 0);
        require(deposit0 <= deposit0Max && deposit1 <= deposit1Max);
        require(to != address(0) && to != address(this), "to");
        require(!whitelisted || list[msg.sender]);

        /// update fees
        (uint128 baseLiquidity, uint128 limitLiquidity) = zeroBurn();

        uint160 sqrtPrice = TickMath.getSqrtRatioAtTick(currentTick());
        uint256 price = FullMath.mulDiv(uint256(sqrtPrice).mul(uint256(sqrtPrice)), PRECISION, 2**(96 * 2));

        (uint256 pool0, uint256 pool1) = getTotalAmounts();

        shares = deposit1.add(deposit0.mul(price).div(PRECISION));

        if (deposit0 > 0) {
          token0.safeTransferFrom(from, address(this), deposit0);
        }
        if (deposit1 > 0) {
          token1.safeTransferFrom(from, address(this), deposit1);
        }

        uint256 total = totalSupply();
        if (total != 0) {
          uint256 pool0PricedInToken1 = pool0.mul(price).div(PRECISION);
          shares = shares.mul(total).div(pool0PricedInToken1.add(pool1));
          if (directDeposit) {
            baseLiquidity = _liquidityForAmounts(
                baseLower,
                baseUpper,
                token0.balanceOf(address(this)),
                token1.balanceOf(address(this))
            );
            _mintLiquidity(baseLower, baseUpper, baseLiquidity, address(this));

            limitLiquidity = _liquidityForAmounts(
                limitLower,
                limitUpper,
                token0.balanceOf(address(this)),
                token1.balanceOf(address(this))
            );
            _mintLiquidity(limitLower, limitUpper, limitLiquidity, address(this));
          }
        }
        _mint(to, shares);
        emit Deposit(from, to, shares, deposit0, deposit1);
        /// Check total supply cap not exceeded. A value of 0 means no limit.
        require(maxTotalSupply == 0 || total <= maxTotalSupply, "max");
    }

    /// @notice Update fees of the positions
    /// @return baseLiquidity Fee of base position
    /// @return limitLiquidity Fee of limit position
    function zeroBurn() internal returns(uint128 baseLiquidity, uint128 limitLiquidity) {
      /// update fees for inclusion
      (baseLiquidity, , ) = _position(baseLower, baseUpper);
      if (baseLiquidity > 0) {
          pool.burn(baseLower, baseUpper, 0);
      }
      (limitLiquidity, , ) = _position(limitLower, limitUpper);
      if (limitLiquidity > 0) {
          pool.burn(limitLower, limitUpper, 0);
      }
    }

    /// @notice Pull liquidity tokens from liquidity and receive the tokens
    /// @param shares Number of liquidity tokens to pull from liquidity
    /// @return base0 amount of token0 received from base position
    /// @return base1 amount of token1 received from base position
    /// @return limit0 amount of token0 received from limit position
    /// @return limit1 amount of token1 received from limit position
    function pullLiquidity(
      uint256 shares
    ) external onlyOwner returns(
        uint256 base0,
        uint256 base1,
        uint256 limit0,
        uint256 limit1
      ) {
        zeroBurn();
        (base0, base1) = _burnLiquidity(
            baseLower,
            baseUpper,
            _liquidityForShares(baseLower, baseUpper, shares),
            address(this),
            false
        );
        (limit0, limit1) = _burnLiquidity(
            limitLower,
            limitUpper,
            _liquidityForShares(limitLower, limitUpper, shares),
            address(this),
            false
        );
    } 

    /// @param shares Number of liquidity tokens to redeem as pool assets
    /// @param to Address to which redeemed pool assets are sent
    /// @param from Address from which liquidity tokens are sent
    /// @return amount0 Amount of token0 redeemed by the submitted liquidity tokens
    /// @return amount1 Amount of token1 redeemed by the submitted liquidity tokens
    function withdraw(
        uint256 shares,
        address to,
        address from
    ) nonReentrant external override returns (uint256 amount0, uint256 amount1) {
        require(shares > 0, "shares");
        require(to != address(0), "to");

        /// update fees
        zeroBurn();

        /// Withdraw liquidity from Uniswap pool
        (uint256 base0, uint256 base1) = _burnLiquidity(
            baseLower,
            baseUpper,
            _liquidityForShares(baseLower, baseUpper, shares),
            to,
            false
        );
        (uint256 limit0, uint256 limit1) = _burnLiquidity(
            limitLower,
            limitUpper,
            _liquidityForShares(limitLower, limitUpper, shares),
            to,
            false
        );

        // Push tokens proportional to unused balances
        uint256 supply = totalSupply();
        uint256 unusedAmount0 = token0.balanceOf(address(this)).mul(shares).div(supply);
        uint256 unusedAmount1 = token1.balanceOf(address(this)).mul(shares).div(supply);
        if (unusedAmount0 > 0) token0.safeTransfer(to, unusedAmount0);
        if (unusedAmount1 > 0) token1.safeTransfer(to, unusedAmount1);

        amount0 = base0.add(limit0).add(unusedAmount0);
        amount1 = base1.add(limit1).add(unusedAmount1);

        require(
            from == msg.sender || IUniversalVault(from).owner() == msg.sender,
            "own"
        );
        _burn(from, shares);

        emit Withdraw(from, to, shares, amount0, amount1);
    }

    /// @param _baseLower The lower tick of the base position
    /// @param _baseUpper The upper tick of the base position
    /// @param _limitLower The lower tick of the limit position
    /// @param _limitUpper The upper tick of the limit position
    /// @param feeRecipient Address of recipient of 10% of earned fees since last rebalance
    /// @param swapQuantity Quantity of tokens to swap; if quantity is positive,
    /// `swapQuantity` token0 are swaped for token1, if negative, `swapQuantity`
    /// token1 is swaped for token0
    /// @param amountMin Minimum Amount of tokens should be received in swap
    function rebalance(
        int24 _baseLower,
        int24 _baseUpper,
        int24 _limitLower,
        int24 _limitUpper,
        address feeRecipient,
        int256 swapQuantity,
        int256 amountMin
    ) nonReentrant external override onlyOwner {
        require(
            _baseLower < _baseUpper &&
                _baseLower % tickSpacing == 0 &&
                _baseUpper % tickSpacing == 0
        );
        require(
            _limitLower < _limitUpper &&
                _limitLower % tickSpacing == 0 &&
                _limitUpper % tickSpacing == 0
        );
        require(
          _limitUpper != _baseUpper ||
          _limitLower != _baseLower
        );
        require(feeRecipient != address(0));

        /// update fees
        (uint128 baseLiquidity, uint128 limitLiquidity) = zeroBurn();

        /// Withdraw all liquidity and collect all fees from Uniswap pool
        (, uint256 feesLimit0, uint256 feesLimit1) = _position(baseLower, baseUpper);
        (, uint256 feesBase0, uint256 feesBase1) = _position(limitLower, limitUpper);

        uint256 fees0 = feesBase0.add(feesLimit0);
        uint256 fees1 = feesBase1.add(feesLimit1);
        (baseLiquidity, , ) = _position(baseLower, baseUpper);
        (limitLiquidity, , ) = _position(limitLower, limitUpper);

        _burnLiquidity(baseLower, baseUpper, baseLiquidity, address(this), true);
        _burnLiquidity(limitLower, limitUpper, limitLiquidity, address(this), true);

        /// transfer 10% of fees for VISR buybacks
        if (fees0 > 0) token0.safeTransfer(feeRecipient, fees0.div(10));
        if (fees1 > 0) token1.safeTransfer(feeRecipient, fees1.div(10));

        emit Rebalance(
            currentTick(),
            token0.balanceOf(address(this)),
            token1.balanceOf(address(this)),
            fees0,
            fees1,
            totalSupply()
        );

        /// swap tokens if required
        if (swapQuantity != 0) {
            rebalanceCalled = true;
            pool.swap(
                address(this),
                swapQuantity > 0,
                swapQuantity > 0 ? swapQuantity : -swapQuantity,
                swapQuantity > 0 ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
                abi.encode(amountMin)
            );
        }

        baseLower = _baseLower;
        baseUpper = _baseUpper;
        baseLiquidity = _liquidityForAmounts(
            baseLower,
            baseUpper,
            token0.balanceOf(address(this)),
            token1.balanceOf(address(this))
        );
        _mintLiquidity(baseLower, baseUpper, baseLiquidity, address(this));

        limitLower = _limitLower;
        limitUpper = _limitUpper;
        limitLiquidity = _liquidityForAmounts(
            limitLower,
            limitUpper,
            token0.balanceOf(address(this)),
            token1.balanceOf(address(this))
        );
        _mintLiquidity(limitLower, limitUpper, limitLiquidity, address(this));
    }

    /// @notice Compound pending fees
    /// @return baseToken0Owed Pending fees of base token0
    /// @return baseToken1Owed Pending fees of base token1
    /// @return limitToken0Owed Pending fees of limit token0
    /// @return limitToken1Owed Pending fees of limit token1
    function compound() external onlyOwner returns (
      uint128 baseToken0Owed,
      uint128 baseToken1Owed,
      uint128 limitToken0Owed,
      uint128 limitToken1Owed
    ) {
      // update fees for compounding
      zeroBurn();
      (, baseToken0Owed,baseToken1Owed) = _position(baseLower, baseUpper);
      (, limitToken0Owed,limitToken1Owed) = _position(limitLower, limitUpper);
      
      // collect fees
      pool.collect(address(this), baseLower, baseLower, baseToken0Owed, baseToken1Owed);
      pool.collect(address(this), limitLower, limitUpper, limitToken0Owed, limitToken1Owed);
      
      uint128 baseLiquidity = _liquidityForAmounts(
        baseLower,
        baseUpper,
        token0.balanceOf(address(this)),
        token1.balanceOf(address(this))
      );
      _mintLiquidity(baseLower, baseUpper, baseLiquidity, address(this));

      uint128 limitLiquidity = _liquidityForAmounts(
        limitLower,
        limitUpper,
        token0.balanceOf(address(this)),
        token1.balanceOf(address(this))
      );
      _mintLiquidity(limitLower, limitUpper, limitLiquidity, address(this));
    }

    /// @notice Add tokens to base liquidity
    /// @param amount0 Amount of token0 to add
    /// @param amount1 Amount of token1 to add
    function addBaseLiquidity(uint256 amount0, uint256 amount1) external onlyOwner {
        uint128 baseLiquidity = _liquidityForAmounts(
            baseLower,
            baseUpper,
            amount0 == 0 && amount1 == 0 ? token0.balanceOf(address(this)) : amount0,
            amount0 == 0 && amount1 == 0 ? token1.balanceOf(address(this)) : amount1
        );
        _mintLiquidity(baseLower, baseUpper, baseLiquidity, address(this));
    }

    /// @notice Add tokens to limit liquidity
    /// @param amount0 Amount of token0 to add
    /// @param amount1 Amount of token1 to add
    function addLimitLiquidity(uint256 amount0, uint256 amount1) external onlyOwner {
        uint128 limitLiquidity = _liquidityForAmounts(
            limitLower,
            limitUpper,
            amount0 == 0 && amount1 == 0 ? token0.balanceOf(address(this)) : amount0,
            amount0 == 0 && amount1 == 0 ? token1.balanceOf(address(this)) : amount1
        );
        _mintLiquidity(limitLower, limitUpper, limitLiquidity, address(this));
    }

    /// @notice Adds the liquidity for the given position
    /// @param tickLower The lower tick of the position in which to add liquidity
    /// @param tickUpper The upper tick of the position in which to add liquidity
    /// @param liquidity The amount of liquidity to mint
    /// @param payer Payer Data
    /// @return amount0 The amount of token0 that was paid to mint the given amount of liquidity
    /// @return amount1 The amount of token1 that was paid to mint the given amount of liquidity
    function _mintLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        address payer
    ) internal returns (uint256 amount0, uint256 amount1) {
        if (liquidity > 0) {
            mintCalled = true;
            (amount0, amount1) = pool.mint(
                address(this),
                tickLower,
                tickUpper,
                liquidity,
                abi.encode(payer)
            );
        }
    }

    /// @notice Burn liquidity from the sender and collect tokens owed for the liquidity
    /// @param tickLower The lower tick of the position for which to burn liquidity
    /// @param tickUpper The upper tick of the position for which to burn liquidity
    /// @param liquidity The amount of liquidity to burn
    /// @param to The address which should receive the fees collected
    /// @param collectAll If true, collect all tokens owed in the pool, else collect the owed tokens of the burn
    /// @return amount0 The amount of fees collected in token0
    /// @return amount1 The amount of fees collected in token1
    function _burnLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        address to,
        bool collectAll
    ) internal returns (uint256 amount0, uint256 amount1) {
        if (liquidity > 0) {
            /// Burn liquidity
            (uint256 owed0, uint256 owed1) = pool.burn(tickLower, tickUpper, liquidity);

            // Collect amount owed
            uint128 collect0 = collectAll ? type(uint128).max : _uint128Safe(owed0);
            uint128 collect1 = collectAll ? type(uint128).max : _uint128Safe(owed1);
            if (collect0 > 0 || collect1 > 0) {
                (amount0, amount1) = pool.collect(to, tickLower, tickUpper, collect0, collect1);
            }
        }
    }

    /// @notice Get the liquidity amount for given liquidity tokens
    /// @param tickLower The lower tick of the position
    /// @param tickUpper The upper tick of the position
    /// @param shares Shares of position
    /// @return The amount of liquidity toekn for shares
    function _liquidityForShares(
        int24 tickLower,
        int24 tickUpper,
        uint256 shares
    ) internal view returns (uint128) {
        (uint128 position, , ) = _position(tickLower, tickUpper);
        return _uint128Safe(uint256(position).mul(shares).div(totalSupply()));
    }

    /// @notice Get the info of the given position
    /// @param tickLower The lower tick of the position
    /// @param tickUpper The upper tick of the position
    /// @return liquidity The amount of liquidity of the position
    /// @return tokensOwed0 Amount of token0 owed
    /// @return tokensOwed1 Amount of token1 owed
    function _position(int24 tickLower, int24 tickUpper)
        internal
        view
        returns (
            uint128 liquidity,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        bytes32 positionKey = keccak256(abi.encodePacked(address(this), tickLower, tickUpper));
        (liquidity, , , tokensOwed0, tokensOwed1) = pool.positions(positionKey);
    }

    /// @notice Callback function of uniswapV3Pool mint
    function uniswapV3MintCallback(
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external override {
        require(msg.sender == address(pool));
        require(mintCalled == true);

        if (amount0 > 0) token0.safeTransfer(msg.sender, amount0);
        if (amount1 > 0) token1.safeTransfer(msg.sender, amount1);
        mintCalled = false;
    }

    /// @notice Callback function of uniswapV3Pool swap
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external override {
        require(msg.sender == address(pool));
        require(rebalanceCalled == true);
        int256 amountMin = abi.decode(data, (int256));

        if (amount0Delta > 0) {
            require(amount0Delta >= amountMin);
            token0.safeTransfer(msg.sender, uint256(amount0Delta));
        } else if (amount1Delta > 0) {
            require(amount1Delta >= amountMin);
            token1.safeTransfer(msg.sender, uint256(amount1Delta));
        }
        rebalanceCalled = false;
    }

    /// @return total0 Quantity of token0 in both positions and unused in the Hypervisor
    /// @return total1 Quantity of token1 in both positions and unused in the Hypervisor
    function getTotalAmounts() public view override returns (uint256 total0, uint256 total1) {
        (, uint256 base0, uint256 base1) = getBasePosition();
        (, uint256 limit0, uint256 limit1) = getLimitPosition();
        total0 = token0.balanceOf(address(this)).add(base0).add(limit0);
        total1 = token1.balanceOf(address(this)).add(base1).add(limit1);
    }

    /// @return liquidity Amount of total liquidity in the base position
    /// @return amount0 Estimated amount of token0 that could be collected by
    /// burning the base position
    /// @return amount1 Estimated amount of token1 that could be collected by
    /// burning the base position
    function getBasePosition()
        public
        view
        returns (
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        (uint128 positionLiquidity, uint128 tokensOwed0, uint128 tokensOwed1) = _position(
            baseLower,
            baseUpper
        );
        (amount0, amount1) = _amountsForLiquidity(baseLower, baseUpper, positionLiquidity);
        amount0 = amount0.add(uint256(tokensOwed0));
        amount1 = amount1.add(uint256(tokensOwed1));
        liquidity = positionLiquidity;
    }

    /// @return liquidity Amount of total liquidity in the limit position
    /// @return amount0 Estimated amount of token0 that could be collected by
    /// burning the limit position
    /// @return amount1 Estimated amount of token1 that could be collected by
    /// burning the limit position
    function getLimitPosition()
        public
        view
        returns (
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        (uint128 positionLiquidity, uint128 tokensOwed0, uint128 tokensOwed1) = _position(
            limitLower,
            limitUpper
        );
        (amount0, amount1) = _amountsForLiquidity(limitLower, limitUpper, positionLiquidity);
        amount0 = amount0.add(uint256(tokensOwed0));
        amount1 = amount1.add(uint256(tokensOwed1));
        liquidity = positionLiquidity;
    }

    /// @notice Get the amounts of the given numbers of liquidity tokens
    /// @param tickLower The lower tick of the position
    /// @param tickUpper The upper tick of the position
    /// @param liquidity The amount of liquidity tokens
    /// @return Amount of token0 and token1
    function _amountsForLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) internal view returns (uint256, uint256) {
        (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
        return
            LiquidityAmounts.getAmountsForLiquidity(
                sqrtRatioX96,
                TickMath.getSqrtRatioAtTick(tickLower),
                TickMath.getSqrtRatioAtTick(tickUpper),
                liquidity
            );
    }

    /// @notice Get the liquidity amount of the given numbers of token0 and token1
    /// @param tickLower The lower tick of the position
    /// @param tickUpper The upper tick of the position
    /// @param amount0 The amount of token0
    /// @param amount0 The amount of token1
    /// @return Amount of liquidity tokens
    function _liquidityForAmounts(
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) internal view returns (uint128) {
        (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
        return
            LiquidityAmounts.getLiquidityForAmounts(
                sqrtRatioX96,
                TickMath.getSqrtRatioAtTick(tickLower),
                TickMath.getSqrtRatioAtTick(tickUpper),
                amount0,
                amount1
            );
    }

    /// @return tick Uniswap pool's current price tick
    function currentTick() public view returns (int24 tick) {
        (, tick, , , , , ) = pool.slot0();
    }

    function _uint128Safe(uint256 x) internal pure returns (uint128) {
        assert(x <= type(uint128).max);
        return uint128(x);
    }

    /// @param _maxTotalSupply The maximum liquidity token supply the contract allows
    function setMaxTotalSupply(uint256 _maxTotalSupply) external onlyOwner {
        maxTotalSupply = _maxTotalSupply;
        emit MaxTotalSupplySet(_maxTotalSupply);
    }

    /// @param _deposit0Max The maximum amount of token0 allowed in a deposit
    /// @param _deposit1Max The maximum amount of token1 allowed in a deposit
    function setDepositMax(uint256 _deposit0Max, uint256 _deposit1Max) external onlyOwner {
        deposit0Max = _deposit0Max;
        deposit1Max = _deposit1Max;
        emit DepositMaxSet(_deposit0Max, _deposit1Max);
    }

    /// @param listed Array of addresses to be appended
    function appendList(address[] memory listed) external onlyOwner {
        for (uint8 i; i < listed.length; i++) {
            list[listed[i]] = true;
        }
    }

    /// @param listed Address of listed to remove
    function removeListed(address listed) external onlyOwner {
        list[listed] = false;
    }

    /// @notice Toggle Direct Deposit
    function toggleDirectDeposit() external onlyOwner {
        directDeposit = !directDeposit;
    }

    /// @notice Toogle Whitelist configuration
    function toggleWhitelist() external onlyOwner {
        whitelisted = !whitelisted;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0));
        owner = newOwner;
    }

    modifier onlyOwner {
        require(msg.sender == owner, "only owner");
        _;
    }
}
