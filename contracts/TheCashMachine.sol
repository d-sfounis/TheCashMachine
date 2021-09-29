// SPDX-License-Identifier: GPL-3.0-only

pragma solidity ^0.8.7;

/***
 *     ______   __  __     ______        ______     ______     ______     __  __        __    __     ______     ______     __  __     __     __   __     ______    
 *    /\__  _\ /\ \_\ \   /\  ___\      /\  ___\   /\  __ \   /\  ___\   /\ \_\ \      /\ "-./  \   /\  __ \   /\  ___\   /\ \_\ \   /\ \   /\ "-.\ \   /\  ___\   
 *    \/_/\ \/ \ \  __ \  \ \  __\      \ \ \____  \ \  __ \  \ \___  \  \ \  __ \     \ \ \-./\ \  \ \  __ \  \ \ \____  \ \  __ \  \ \ \  \ \ \-.  \  \ \  __\   
 *       \ \_\  \ \_\ \_\  \ \_____\     \ \_____\  \ \_\ \_\  \/\_____\  \ \_\ \_\     \ \_\ \ \_\  \ \_\ \_\  \ \_____\  \ \_\ \_\  \ \_\  \ \_\\"\_\  \ \_____\ 
 *        \/_/   \/_/\/_/   \/_____/      \/_____/   \/_/\/_/   \/_____/   \/_/\/_/      \/_/  \/_/   \/_/\/_/   \/_____/   \/_/\/_/   \/_/   \/_/ \/_/   \/_____/ 
 *                                                                                                                                                                 
 *   https://t.me/the_cash_machine                                                              
 */

/* Our lib imports. Mostly OpenZeppelin stuff */
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/* UniSwap - PancakeSwap interfaces, so we can store references to the pair, once created at construction time. */
interface IDEXFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IDEXRouter {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);

    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

interface IDividendDistributor {
    function changeToken(address newToken) external;
    function setDistributionCriteria(uint256 _minPeriod, uint256 _minDistribution) external;
    function setShare(address shareholder, uint256 amount) external;
    function deposit() external payable;
    function process(uint256 gas) external;
}

contract DividendDistributor is IDividendDistributor {
    using SafeMath for uint256;

    address _token;

    struct Share {
        uint256 amount;
        uint256 totalExcluded;
        uint256 totalRealised;
    }

    //IERC20 TOKEN = IERC20(0x3EE2200Efb3400fAbB9AacF31297cBdD1d435D47); //Binance-pegged Cardano Token (ADA)
    //IERC20 TOKEN = IERC20(0x07865c6E87B9F70255377e024ace6630C1Eaa37F); //Ropsten USDC
    IERC20 TOKEN = IERC20(0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8); //Arbitrum USDC
    //address WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    IDEXRouter router;

    address[] shareholders;
    mapping (address => uint256) shareholderIndexes;
    mapping (address => uint256) shareholderClaims;

    mapping (address => Share) public shares;

    uint256 public totalShares;
    uint256 public totalDividends;
    uint256 public totalDistributed;
    uint256 public dividendsPerShare;
    uint256 public dividendsPerShareAccuracyFactor = 10 ** 36;

    uint256 public minPeriod = 5 minutes;
    uint256 public minDistribution = 1 * (10 ** 18);

    uint256 currentIndex;

    bool initialized;
    modifier initialization() {
        require(!initialized);
        _;
        initialized = true;
    }

    modifier onlyToken() {
        require(msg.sender == _token); _;
    }

    constructor (address _router) {
        router = _router != address(0)
            ? IDEXRouter(_router)
            : IDEXRouter(0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506); //IDEXRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);
        _token = msg.sender;
    }
    
    function changeToken(address newToken) external override onlyToken {
        uint256 previousAmount = TOKEN.balanceOf(address(this));
        require(totalDividends == 0 || previousAmount > 0, "TCM DIVIDEND DISTRIBUTOR: Requires at least some of the initial token to calculate convertion rate.");
        
        if (previousAmount > 0) {
            address[] memory path = new address[](2);
            path[0] = address(TOKEN);
            path[1] = address(newToken);
    
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                previousAmount,
                0,
                path,
                address(this),
                block.timestamp
            );
        }
        
        TOKEN = IERC20(newToken);
        
        if (totalDividends > 0) {
            uint256 amount = TOKEN.balanceOf(address(this));
    
            totalDividends = totalDividends.mul(amount).div(previousAmount);
            dividendsPerShare = dividendsPerShare.mul(amount).div(previousAmount);
        }
    }

    function setDistributionCriteria(uint256 _minPeriod, uint256 _minDistribution) external override onlyToken {
        minPeriod = _minPeriod;
        minDistribution = _minDistribution * (10 ** 18);
    }

    function setShare(address shareholder, uint256 amount) external override onlyToken {
        if(shares[shareholder].amount > 0){
            distributeDividend(shareholder);
        }

        if(amount > 0 && shares[shareholder].amount == 0){
            addShareholder(shareholder);
        }else if(amount == 0 && shares[shareholder].amount > 0){
            removeShareholder(shareholder);
        }

        totalShares = totalShares.sub(shares[shareholder].amount).add(amount);
        shares[shareholder].amount = amount;
        shares[shareholder].totalExcluded = getCumulativeDividends(shares[shareholder].amount);
    }

    function deposit() external payable override onlyToken {
        uint256 balanceBefore = TOKEN.balanceOf(address(this));

        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = address(TOKEN);

        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: msg.value}(
            0,
            path,
            address(this),
            block.timestamp
        );

        uint256 amount = TOKEN.balanceOf(address(this)).sub(balanceBefore);

        totalDividends = totalDividends.add(amount);
        dividendsPerShare = dividendsPerShare.add(dividendsPerShareAccuracyFactor.mul(amount).div(totalShares));
    }

    function process(uint256 gas) external override onlyToken {
        uint256 shareholderCount = shareholders.length;

        if(shareholderCount == 0) { return; }

        uint256 gasUsed = 0;
        uint256 gasLeft = gasleft();

        uint256 iterations = 0;

        while(gasUsed < gas && iterations < shareholderCount) {
            if(currentIndex >= shareholderCount){
                currentIndex = 0;
            }

            if(shouldDistribute(shareholders[currentIndex])){
                distributeDividend(shareholders[currentIndex]);
            }

            gasUsed = gasUsed.add(gasLeft.sub(gasleft()));
            gasLeft = gasleft();
            currentIndex++;
            iterations++;
        }
    }

    function shouldDistribute(address shareholder) internal view returns (bool) {
        return shareholderClaims[shareholder] + minPeriod < block.timestamp
                && getUnpaidEarnings(shareholder) > minDistribution;
    }

    function TimeLeftToDistribute(address shareholder) public view returns (uint256) {
        uint256 timeleft;
        if (shareholderClaims[shareholder] + minPeriod > block.timestamp) {
            timeleft = shareholderClaims[shareholder] + minPeriod - block.timestamp;
        } else {
            timeleft = 0;
        }
        return timeleft;
    }   
    
    function distributeDividend(address shareholder) internal {
        if(shares[shareholder].amount == 0){ return; }

        uint256 amount = getUnpaidEarnings(shareholder);
        if(amount > 0){
            totalDistributed = totalDistributed.add(amount);
            TOKEN.transfer(shareholder, amount);
            shareholderClaims[shareholder] = block.timestamp;
            shares[shareholder].totalRealised = shares[shareholder].totalRealised.add(amount);
            shares[shareholder].totalExcluded = getCumulativeDividends(shares[shareholder].amount);
        }
    }

    function claimDividend() external {
        distributeDividend(msg.sender);
    }

    function getUnpaidEarnings(address shareholder) public view returns (uint256) {
        if(shares[shareholder].amount == 0){ return 0; }

        uint256 shareholderTotalDividends = getCumulativeDividends(shares[shareholder].amount);
        uint256 shareholderTotalExcluded = shares[shareholder].totalExcluded;

        if(shareholderTotalDividends <= shareholderTotalExcluded){ return 0; }

        return shareholderTotalDividends.sub(shareholderTotalExcluded);
    }

    function getCumulativeDividends(uint256 share) internal view returns (uint256) {
        return share.mul(dividendsPerShare).div(dividendsPerShareAccuracyFactor);
    }

    function addShareholder(address shareholder) internal {
        shareholderIndexes[shareholder] = shareholders.length;
        shareholders.push(shareholder);
    }

    function removeShareholder(address shareholder) internal {
        shareholders[shareholderIndexes[shareholder]] = shareholders[shareholders.length-1];
        shareholderIndexes[shareholders[shareholders.length-1]] = shareholderIndexes[shareholder];
        shareholders.pop();
    }
}

contract TheCashMachine is IERC20, Ownable {
    using SafeMath for uint256;
    using Address for address;
    
    event AutoLiquify(uint256 amountBNB, uint256 amountBOG);
    event BuybackMultiplierActive(uint256 duration);
    event CallInvocationResults(bool success, bytes data);
    
    //address WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;  //Arbitrum WETH
    address DEAD = 0x000000000000000000000000000000000000dEaD;
    address ZERO = 0x0000000000000000000000000000000000000000;
    string public currentlyServing = "USDC (Arbitrum)";

    string constant _name = "The Cash Machine";
    string constant _symbol = "TCM";
    uint8 constant _decimals = 6;

    uint256 _totalSupply = 10000000 * (10 ** _decimals); // 10 Billion
    uint256 public _maxTxAmount = (_totalSupply * 1) / 100; // 1% of total supply
    uint256 public _maxWalletSize = (_totalSupply * 2) / 100; // 2%
    
    uint256 public anti_sniper_blocks = 3;
    bool public txLimitFailsafe = true;

    mapping (address => uint256) _balances;
    mapping (address => mapping (address => uint256)) _allowances;

    mapping(address => bool) public isFeeExempt;
    mapping(address => bool) public isTxLimitExempt;
    mapping(address => bool) public isDividendExempt;

    uint256 liquidityFee = 0; //Used to be 200 == 2%
    uint256 buybackFee = 0;
    uint256 reflectionFee = 1000;
    uint256 marketingFee = 500;
    uint256 totalFee = 1500;
    uint256 feeDenominator = 10000;
    uint256 public _sellMultiplierNumerator = 200;
    uint256 public _sellMultiplierDenominator = 100;
    bool public penalizingSalesEnabled = false;

    address public autoLiquidityReceiver;
    address public marketingFeeReceiver;

    uint256 targetLiquidity = 30;
    uint256 targetLiquidityDenominator = 100;

    IDEXRouter public router;
    address public pair;

    uint256 public launchedAt;

    uint256 buybackMultiplierTriggeredAt;
    uint256 buybackMultiplierLength = 30 minutes;

    bool public autoBuybackEnabled = false;
    uint256 autoBuybackCap;
    uint256 autoBuybackAccumulator;
    uint256 autoBuybackAmount;
    uint256 autoBuybackBlockPeriod;
    uint256 autoBuybackBlockLast;

    DividendDistributor public distributor;
    uint256 distributorGas = 500000;

    bool public swapEnabled = true;
    uint256 public swapThreshold = _totalSupply / 2000; // 0.05%
    bool inSwap;
    modifier swapping() { inSwap = true; _; inSwap = false; }

    constructor(address AutoLiqLocker, address marketingWallet) {
        //router = IDEXRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E); //Pancake Router v2 (mainnet)
        //router = IDEXRouter(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D); //Uniswap V2 Router on Ropsten
        router = IDEXRouter(0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506); //Sushi V2 Router on Arbitrum
        pair = IDEXFactory(router.factory()).createPair(WETH, address(this));
        _allowances[msg.sender][address(router)] = type(uint256).max;
        _allowances[address(this)][address(router)] = type(uint256).max;

        distributor = new DividendDistributor(address(router));

        isFeeExempt[msg.sender] = true;
        isTxLimitExempt[address(this)] = true;
        isTxLimitExempt[msg.sender] = true;
        isTxLimitExempt[address(router)] = true;
        isDividendExempt[pair] = true;
        isDividendExempt[address(this)] = true;
        isDividendExempt[DEAD] = true;
        isDividendExempt[ZERO] = true;
        autoLiquidityReceiver = AutoLiqLocker;
        marketingFeeReceiver = marketingWallet;

        _balances[msg.sender] = _totalSupply;
        emit Transfer(address(0), msg.sender, _totalSupply);
    }

    receive() external payable {}
    
    /* Interface for the internal distributor contract */
    function getUnpaidEarnings(address shareholder) public view returns (uint256) { return distributor.getUnpaidEarnings(shareholder); }
    function claimDividend() public { distributor.claimDividend(); }
    /*function TimeLeftToDistribute(address shareholder) public view returns (uint256) { return distributor.TimeLeftToDistribute(shareholder); }
    function totalShares() public view returns (uint256) { return distributor.totalShares(); }
    function totalDividends() public view returns (uint256) { return distributor.totalDividends(); }
    function totalDistributed() public view returns (uint256) { return distributor.totalDistributed(); }
    function dividendsPerShare() public view returns (uint256) { return distributor.dividendsPerShare(); }
    function minDistribution() public view returns (uint256) { return distributor.minDistribution(); }*/

    function totalSupply() external view override returns (uint256) { return _totalSupply; }
    function decimals() external pure returns (uint8) { return _decimals; }
    function symbol() external pure returns (string memory) { return _symbol; }
    function name() external pure returns (string memory) { return _name; }
    function getOwner() external view returns (address) { return owner(); }
    function balanceOf(address account) public view override returns (uint256) { return _balances[account]; }
    function allowance(address holder, address spender) external view override returns (uint256) { return _allowances[holder][spender]; }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function approveMax(address spender) external returns (bool) {
        return approve(spender, type(uint256).max);
    }

    function transfer(address recipient, uint256 amount) external override returns (bool) {
        return _transferFrom(msg.sender, recipient, amount);
    }

    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
        if(_allowances[sender][msg.sender] != type(uint256).max){
            _allowances[sender][msg.sender] = _allowances[sender][msg.sender].sub(amount, "Insufficient Allowance");
        }

        return _transferFrom(sender, recipient, amount);
    }

    function _transferFrom(address sender, address recipient, uint256 amount) internal returns (bool) {
        if(inSwap){ return _basicTransfer(sender, recipient, amount); }
        
        if(txLimitFailsafe){
            checkTxLimit(sender, amount); //Will fail a require() if the tx amount is too large.
        }
        
        if (recipient != pair && recipient != DEAD) {
            require(isTxLimitExempt[recipient] || _balances[recipient] + amount <= _maxWalletSize, "TCM: Recipient wallet will exceed max wallet size, blyat.");
        }

        if(shouldSwapBack()){ swapBack(); }
        if(shouldAutoBuyback()){ triggerAutoBuyback(); }

        if(!launched() && recipient == pair){ require(_balances[sender] > 0); launch(); }

        _balances[sender] = _balances[sender].sub(amount, "TCM: Insufficient balance.");

        uint256 amountReceived = shouldTakeFee(sender) ? takeFee(sender, recipient, amount) : amount;
        _balances[recipient] = _balances[recipient].add(amountReceived);

        if(!isDividendExempt[sender]){ try distributor.setShare(sender, _balances[sender]) {} catch {} }
        if(!isDividendExempt[recipient]){ try distributor.setShare(recipient, _balances[recipient]) {} catch {} }

        try distributor.process(distributorGas) {} catch {}

        emit Transfer(sender, recipient, amountReceived);
        return true;
    }

    function _basicTransfer(address sender, address recipient, uint256 amount) internal returns (bool) {
        _balances[sender] = _balances[sender].sub(amount, "TCM: Insufficient balance.");
        _balances[recipient] = _balances[recipient].add(amount);
        emit Transfer(sender, recipient, amount);
        return true;
    }

    function checkTxLimit(address sender, uint256 amount) internal view {
        require(amount <= _maxTxAmount || isTxLimitExempt[sender], "TCM: Max tx_limit Exceeded.");
    }

    function shouldTakeFee(address sender) internal view returns (bool) {
        return !isFeeExempt[sender];
    }

    function getTotalFee(bool selling) public view returns (uint256) {
        if(launchedAt + anti_sniper_blocks >= block.number){ return feeDenominator.sub(1); }
        if(selling && penalizingSalesEnabled) { 
            return totalFee.mul(_sellMultiplierNumerator).div(_sellMultiplierDenominator); 
            }
        return totalFee;
    }

    function takeFee(address sender, address receiver, uint256 amount) internal returns (uint256) {
        uint256 feeAmount = amount.mul(getTotalFee(receiver == pair)).div(feeDenominator);

        _balances[address(this)] = _balances[address(this)].add(feeAmount);
        emit Transfer(sender, address(this), feeAmount);

        return amount.sub(feeAmount);
    }

    function shouldSwapBack() internal view returns (bool) {
        return msg.sender != pair
        && !inSwap
        && swapEnabled
        && _balances[address(this)] >= swapThreshold;
    }

    function swapBack() internal swapping { //WORKSPACE
        uint256 dynamicLiquidityFee = isOverLiquified(targetLiquidity, targetLiquidityDenominator) ? 0 : liquidityFee;
        uint256 amountToLiquify = swapThreshold.mul(dynamicLiquidityFee).div(totalFee).div(2);
        uint256 amountToSwap = swapThreshold.sub(amountToLiquify);

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = WETH;

        uint256 balanceBefore = address(this).balance;

        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amountToSwap,
            0,
            path,
            address(this),
            block.timestamp
        );

        uint256 amountBNB = address(this).balance.sub(balanceBefore);

        uint256 totalBNBFee = totalFee.sub(dynamicLiquidityFee.div(2));

        uint256 amountBNBLiquidity = amountBNB.mul(dynamicLiquidityFee).div(totalBNBFee).div(2);
        uint256 amountBNBReflection = amountBNB.mul(reflectionFee).div(totalBNBFee);
        uint256 amountBNBMarketing = amountBNB.mul(marketingFee).div(totalBNBFee);

        try distributor.deposit{value: amountBNBReflection}() {} catch {}
        
        (bool success, bytes memory data) = payable(marketingFeeReceiver).call{value: amountBNBMarketing, gas: 30000}("");
        emit CallInvocationResults(success, data);

        if(amountToLiquify > 0){
            router.addLiquidityETH{value: amountBNBLiquidity}(
                address(this),
                amountToLiquify,
                0,
                0,
                autoLiquidityReceiver,
                block.timestamp
            );
            emit AutoLiquify(amountBNBLiquidity, amountToLiquify);
        }
    }

    function shouldAutoBuyback() internal view returns (bool) {
        return msg.sender != pair
            && !inSwap
            && autoBuybackEnabled
            && autoBuybackBlockLast + autoBuybackBlockPeriod <= block.number
            && address(this).balance >= autoBuybackAmount;
    }

    function triggerManualBuyback(uint256 amount, bool triggerBuybackMultiplier) external onlyOwner {
        buyTokens(amount, DEAD);
        if(triggerBuybackMultiplier){
            buybackMultiplierTriggeredAt = block.timestamp;
            emit BuybackMultiplierActive(buybackMultiplierLength);
        }
    }

    function clearBuybackMultiplier() external onlyOwner {
        buybackMultiplierTriggeredAt = 0;
    }

    function triggerAutoBuyback() internal {
        buyTokens(autoBuybackAmount, DEAD);
        autoBuybackBlockLast = block.number;
        autoBuybackAccumulator = autoBuybackAccumulator.add(autoBuybackAmount);
        if(autoBuybackAccumulator > autoBuybackCap){ autoBuybackEnabled = false; }
    }

    function buyTokens(uint256 amount, address to) internal swapping {
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = address(this);

        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: amount}(
            0,
            path,
            to,
            block.timestamp
        );
    }

    function setAutoBuybackSettings(bool _enabled, uint256 _cap, uint256 _amount, uint256 _period) external onlyOwner {
        autoBuybackEnabled = _enabled;
        autoBuybackCap = _cap;
        autoBuybackAccumulator = 0;
        autoBuybackAmount = _amount.div(100);
        autoBuybackBlockPeriod = _period;
        autoBuybackBlockLast = block.number;
    }
    
    function setAntiSniperBlocks(uint256 blocks) public onlyOwner {
        require(blocks <= 10, "TCM: You're looking too far ahead for anti-sniping, cyka!");
        anti_sniper_blocks = blocks;
    }
    
    function setTxLimitFailsafe(bool toggle) public onlyOwner {
        txLimitFailsafe = toggle;
    }

    function launched() internal view returns (bool) {
        return launchedAt != 0;
    }

    function launch() internal {
        launchedAt = block.number;
    }

    function setTxLimit(uint256 numerator, uint256 divisor) external onlyOwner {
        require(numerator > 0 && divisor > 0 && divisor <= 10000);
        _maxTxAmount = _totalSupply.mul(numerator).div(divisor);
    }
    
    function setReflectToken(address newToken) external onlyOwner {
        require(newToken.isContract(), "Enter valid contract address");
        distributor.changeToken(newToken);
    }
    
    function setMaxWallet(uint256 numerator, uint256 divisor) external onlyOwner() {
        require(numerator > 0 && divisor > 0 && divisor <= 10000);
        _maxWalletSize = _totalSupply.mul(numerator).div(divisor);
    }
    
    function setSellMultiplier(uint256 numerator, uint256 divisor) external onlyOwner() {
        require(numerator > 0 && divisor > 0 && numerator / divisor <= 2);
        _sellMultiplierNumerator = numerator;
        _sellMultiplierDenominator = divisor;
    }

    function setIsDividendExempt(address holder, bool exempt) external onlyOwner {
        require(holder != address(this) && holder != pair);
        isDividendExempt[holder] = exempt;
        if(exempt){
            distributor.setShare(holder, 0);
        }else{
            distributor.setShare(holder, _balances[holder]);
        }
    }

    function setIsFeeExempt(address holder, bool exempt) external onlyOwner {
        isFeeExempt[holder] = exempt;
    }

    function setIsTxLimitExempt(address holder, bool exempt) external onlyOwner {
        isTxLimitExempt[holder] = exempt;
    }

    function setFees(uint256 _liquidityFee, uint256 _buybackFee, uint256 _reflectionFee, uint256 _marketingFee, uint256 _feeDenominator) external onlyOwner {
        liquidityFee = _liquidityFee;
        buybackFee = _buybackFee;
        reflectionFee = _reflectionFee;
        marketingFee = _marketingFee;
        totalFee = _liquidityFee.add(_buybackFee).add(_reflectionFee).add(_marketingFee);
        feeDenominator = _feeDenominator;
        require(totalFee < feeDenominator/4);
    }

    function setFeeReceivers(address _autoLiquidityReceiver, address _marketingFeeReceiver) external onlyOwner {
        autoLiquidityReceiver = _autoLiquidityReceiver;
        marketingFeeReceiver = _marketingFeeReceiver;
    }

    function setSwapBackSettings(bool _enabled, uint256 _denominator) external onlyOwner {
        require(_denominator > 0);
        swapEnabled = _enabled;
        swapThreshold = _totalSupply.div(_denominator);
    }

    function setTargetLiquidity(uint256 _target, uint256 _denominator) external onlyOwner {
        targetLiquidity = _target;
        targetLiquidityDenominator = _denominator;
    }

    function setDistributionCriteria(uint256 _minPeriod, uint256 _minDistribution) external onlyOwner {
        distributor.setDistributionCriteria(_minPeriod, _minDistribution);
    }

    function setDistributorSettings(uint256 gas) external onlyOwner {
        require(gas < 750000);
        distributorGas = gas;
    }

    function getCirculatingSupply() public view returns (uint256) {
        return _totalSupply.sub(balanceOf(DEAD)).sub(balanceOf(ZERO));
    }

    function getLiquidityBacking(uint256 accuracy) public view returns (uint256) {
        return accuracy.mul(balanceOf(pair).mul(2)).div(getCirculatingSupply());
    }

    function isOverLiquified(uint256 target, uint256 accuracy) public view returns (bool) {
        return getLiquidityBacking(accuracy) > target;
    }
    
    function setPenalzingSales(bool toggle) external onlyOwner {
        penalizingSalesEnabled = toggle;
    }
    
    function getAllFees() external view returns (uint256 _liquidityFee, uint256 _buybackFee, uint256 _reflectionFee, uint256 _marketingFee, uint256 _totalFee, uint256 _feeDenominator) {
        return (liquidityFee, buybackFee, reflectionFee, marketingFee, totalFee, feeDenominator);
    }

}
