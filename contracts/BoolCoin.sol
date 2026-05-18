// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract Ownable {
    address public owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}

contract ERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external virtual returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external virtual returns (bool) {
        uint256 currentAllowance = allowance[from][msg.sender];
        require(currentAllowance >= amount, "allowance");
        if (currentAllowance != type(uint256).max) {
            allowance[from][msg.sender] = currentAllowance - amount;
            emit Approval(from, msg.sender, allowance[from][msg.sender]);
        }
        _transfer(from, to, amount);
        return true;
    }

    function _mint(address to, uint256 amount) internal {
        require(to != address(0), "zero to");
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal virtual {
        require(to != address(0), "zero to");
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

contract MockUSDT is ERC20, Ownable {
    constructor() ERC20("Mock USDT", "USDT", 18) {}

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}

contract PriceKeeper is Ownable {
    mapping(address => bool) public keepers;
    mapping(uint256 => uint256) public dailyOpenPrice;
    uint256 public currentPrice;

    event KeeperSet(address indexed keeper, bool allowed);
    event DailyOpenPriceSet(uint256 indexed day, uint256 price);
    event CurrentPriceSet(uint256 price);

    modifier onlyKeeper() {
        require(msg.sender == owner || keepers[msg.sender], "not keeper");
        _;
    }

    function setKeeper(address keeper, bool allowed) external onlyOwner {
        keepers[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    function setDailyOpenPrice(uint256 day, uint256 price) external onlyKeeper {
        require(price > 0, "bad price");
        dailyOpenPrice[day] = price;
        currentPrice = price;
        emit DailyOpenPriceSet(day, price);
        emit CurrentPriceSet(price);
    }

    function setCurrentPrice(uint256 price) external onlyKeeper {
        require(price > 0, "bad price");
        currentPrice = price;
        emit CurrentPriceSet(price);
    }
}

contract RewardVault is Ownable {
    IERC20 public immutable usdt;
    mapping(address => bool) public authorized;
    mapping(address => mapping(uint8 => uint256)) public pendingRewards;

    event AuthorizedSet(address indexed account, bool allowed);
    event RewardCredited(address indexed account, uint8 indexed rewardType, uint256 amount);
    event RewardClaimed(address indexed account, uint8 indexed rewardType, uint256 amount);

    constructor(IERC20 usdt_) {
        usdt = usdt_;
    }

    modifier onlyAuthorized() {
        require(msg.sender == owner || authorized[msg.sender], "not authorized");
        _;
    }

    function setAuthorized(address account, bool allowed) external onlyOwner {
        authorized[account] = allowed;
        emit AuthorizedSet(account, allowed);
    }

    function credit(address account, uint8 rewardType, uint256 amount) external onlyAuthorized {
        require(account != address(0), "zero account");
        require(amount > 0, "zero amount");
        pendingRewards[account][rewardType] += amount;
        emit RewardCredited(account, rewardType, amount);
    }

    function claim(uint8 rewardType) external {
        uint256 amount = pendingRewards[msg.sender][rewardType];
        require(amount > 0, "nothing to claim");
        pendingRewards[msg.sender][rewardType] = 0;
        require(usdt.transfer(msg.sender, amount), "usdt transfer failed");
        emit RewardClaimed(msg.sender, rewardType, amount);
    }
}

contract ProjectNFT is Ownable {
    string public name;
    string public symbol;
    uint256 public immutable maxSupply;
    uint256 public totalSupply;

    mapping(uint256 => address) public ownerOf;
    mapping(address => uint256) public balanceOf;
    mapping(address => bool) public minters;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event MinterSet(address indexed minter, bool allowed);

    constructor(string memory name_, string memory symbol_, uint256 maxSupply_) {
        name = name_;
        symbol = symbol_;
        maxSupply = maxSupply_;
    }

    modifier onlyMinter() {
        require(msg.sender == owner || minters[msg.sender], "not minter");
        _;
    }

    function setMinter(address minter, bool allowed) external onlyOwner {
        minters[minter] = allowed;
        emit MinterSet(minter, allowed);
    }

    function mint(address to) external onlyMinter returns (uint256 tokenId) {
        require(to != address(0), "zero to");
        require(totalSupply < maxSupply, "sold out");
        tokenId = ++totalSupply;
        ownerOf[tokenId] = to;
        balanceOf[to] += 1;
        emit Transfer(address(0), to, tokenId);
    }
}

contract PositionLedger is Ownable {
    enum PositionKind {
        Genesis,
        Node,
        StaticDeposit
    }

    struct Position {
        address account;
        PositionKind kind;
        uint256 sourceId;
        uint256 principal;
        uint256 cap;
        uint256 released;
        bool closed;
    }

    uint256 public nextPositionId = 1;
    RewardVault public rewardVault;
    mapping(uint256 => Position) public positions;
    mapping(address => uint256[]) private userPositionIds;
    mapping(address => bool) public authorized;

    event AuthorizedSet(address indexed account, bool allowed);
    event RewardVaultSet(address indexed vault);
    event PositionOpened(
        uint256 indexed positionId,
        address indexed account,
        PositionKind indexed kind,
        uint256 sourceId,
        uint256 principal,
        uint256 cap
    );
    event PositionReleased(uint256 indexed positionId, uint256 amount, uint256 released, bool closed);
    event PositionRewardCredited(
        uint256 indexed positionId,
        address indexed account,
        uint8 indexed rewardType,
        uint256 amount
    );

    modifier onlyAuthorized() {
        require(msg.sender == owner || authorized[msg.sender], "not authorized");
        _;
    }

    function setAuthorized(address account, bool allowed) external onlyOwner {
        authorized[account] = allowed;
        emit AuthorizedSet(account, allowed);
    }

    function setRewardVault(RewardVault vault_) external onlyOwner {
        require(address(vault_) != address(0), "zero vault");
        rewardVault = vault_;
        emit RewardVaultSet(address(vault_));
    }

    function openPosition(
        address account,
        PositionKind kind,
        uint256 sourceId,
        uint256 principal,
        uint256 multiplier
    ) external onlyAuthorized returns (uint256 positionId) {
        require(account != address(0), "zero account");
        require(principal > 0, "zero principal");
        require(multiplier > 0, "zero multiplier");

        positionId = nextPositionId++;
        uint256 cap = principal * multiplier;
        positions[positionId] = Position(account, kind, sourceId, principal, cap, 0, false);
        userPositionIds[account].push(positionId);

        emit PositionOpened(positionId, account, kind, sourceId, principal, cap);
    }

    function accrue(uint256 positionId, uint256 amount) external onlyAuthorized returns (uint256 credited) {
        credited = _accrue(positionId, amount);
    }

    function releaseToVault(
        uint256 positionId,
        uint256 amount,
        uint8 rewardType
    ) external onlyAuthorized returns (uint256 credited) {
        require(address(rewardVault) != address(0), "vault unset");
        credited = _accrue(positionId, amount);
        rewardVault.credit(positions[positionId].account, rewardType, credited);
        emit PositionRewardCredited(positionId, positions[positionId].account, rewardType, credited);
    }

    function _accrue(uint256 positionId, uint256 amount) internal returns (uint256 credited) {
        Position storage position = positions[positionId];
        require(position.account != address(0), "bad position");
        require(!position.closed, "closed");
        require(amount > 0, "zero amount");

        uint256 remaining = position.cap - position.released;
        credited = amount > remaining ? remaining : amount;
        position.released += credited;
        if (position.released == position.cap) {
            position.closed = true;
        }

        emit PositionReleased(positionId, credited, position.released, position.closed);
    }

    function userPositions(address account) external view returns (uint256[] memory) {
        return userPositionIds[account];
    }

    function userPositionDetails(address account) external view returns (Position[] memory details) {
        uint256[] storage ids = userPositionIds[account];
        details = new Position[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            details[i] = positions[ids[i]];
        }
    }
}

contract BOOLToken is ERC20, Ownable {
    uint256 public constant BUY_TAX_BPS = 500;
    uint256 public constant SELL_TAX_BPS = 500;
    uint256 public constant DROP_EXTRA_TAX_BPS = 1000;
    uint256 public constant PROFIT_TAX_BPS = 2500;
    uint256 public constant BPS = 10_000;

    IERC20 public immutable usdt;
    PriceKeeper public priceKeeper;
    address public taxWallet;
    uint256 public openPriceDay;
    uint256 public buyTaxBoolAccrued;
    uint256 public sellTaxBoolAccrued;
    uint256 public profitLpUsdtAccrued;
    uint256 public profitCommunityUsdtAccrued;

    mapping(address => bool) public ammPairs;
    mapping(address => bool) public taxExempt;
    mapping(address => bool) public costManagers;
    mapping(address => uint256) public trackedBoolBalance;
    mapping(address => uint256) public trackedUsdtCost;

    event AmmPairSet(address indexed pair, bool allowed);
    event TaxExemptSet(address indexed account, bool exempt);
    event CostManagerSet(address indexed account, bool allowed);
    event TaxWalletSet(address indexed wallet);
    event PriceKeeperSet(address indexed keeper);
    event OpenPriceDaySet(uint256 day);
    event TradeTaxTaken(address indexed account, bool indexed isSell, uint256 taxBps, uint256 boolTax);
    event ProfitTaxTaken(address indexed account, uint256 soldBool, uint256 profitUsdt, uint256 taxUsdt);
    event PurchaseCostRecorded(address indexed account, uint256 boolAmount, uint256 usdtCost);

    constructor(IERC20 usdt_, address taxWallet_) ERC20("BOOL", "BOOL", 18) {
        require(taxWallet_ != address(0), "zero wallet");
        usdt = usdt_;
        taxWallet = taxWallet_;
        taxExempt[msg.sender] = true;
        taxExempt[taxWallet_] = true;
        _mint(msg.sender, 1_000_000_000 ether);
    }

    function setAmmPair(address pair, bool allowed) external onlyOwner {
        ammPairs[pair] = allowed;
        emit AmmPairSet(pair, allowed);
    }

    function setTaxExempt(address account, bool exempt) external onlyOwner {
        taxExempt[account] = exempt;
        emit TaxExemptSet(account, exempt);
    }

    function setCostManager(address account, bool allowed) external onlyOwner {
        costManagers[account] = allowed;
        emit CostManagerSet(account, allowed);
    }

    function setTaxWallet(address wallet) external onlyOwner {
        require(wallet != address(0), "zero wallet");
        taxWallet = wallet;
        emit TaxWalletSet(wallet);
    }

    function setPriceKeeper(PriceKeeper keeper) external onlyOwner {
        priceKeeper = keeper;
        emit PriceKeeperSet(address(keeper));
    }

    function setOpenPriceDay(uint256 day) external onlyOwner {
        openPriceDay = day;
        emit OpenPriceDaySet(day);
    }

    function averageCost(address account) external view returns (uint256) {
        uint256 balance = trackedBoolBalance[account];
        if (balance == 0) {
            return 0;
        }
        return (trackedUsdtCost[account] * 1 ether) / balance;
    }

    function recordPurchaseCost(address account, uint256 boolAmount, uint256 usdtCost) external {
        require(msg.sender == owner || costManagers[msg.sender], "not cost manager");
        require(account != address(0), "zero account");
        require(boolAmount > 0 && usdtCost > 0, "zero cost");
        trackedBoolBalance[account] += boolAmount;
        trackedUsdtCost[account] += usdtCost;
        emit PurchaseCostRecorded(account, boolAmount, usdtCost);
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        if (taxExempt[from] || taxExempt[to]) {
            super._transfer(from, to, amount);
            return;
        }

        if (ammPairs[from]) {
            uint256 fee = (amount * BUY_TAX_BPS) / BPS;
            uint256 net = amount - fee;
            buyTaxBoolAccrued += fee;
            super._transfer(from, taxWallet, fee);
            super._transfer(from, to, net);
            _increaseCost(to, net);
            emit TradeTaxTaken(to, false, BUY_TAX_BPS, fee);
            return;
        }

        if (ammPairs[to]) {
            uint256 taxBps = currentSellTaxBps();
            uint256 fee = (amount * taxBps) / BPS;
            uint256 net = amount - fee;
            _takeProfitTax(from, amount);
            _decreaseCost(from, amount);
            sellTaxBoolAccrued += fee;
            super._transfer(from, taxWallet, fee);
            super._transfer(from, to, net);
            emit TradeTaxTaken(from, true, taxBps, fee);
            return;
        }

        super._transfer(from, to, amount);
    }

    function currentSellTaxBps() public view returns (uint256) {
        if (address(priceKeeper) == address(0)) {
            return SELL_TAX_BPS;
        }
        uint256 openPrice = priceKeeper.dailyOpenPrice(openPriceDay);
        uint256 currentPrice = priceKeeper.currentPrice();
        if (openPrice == 0 || currentPrice == 0) {
            return SELL_TAX_BPS;
        }
        if (currentPrice * 100 <= openPrice * 90) {
            return SELL_TAX_BPS + DROP_EXTRA_TAX_BPS;
        }
        return SELL_TAX_BPS;
    }

    function _increaseCost(address account, uint256 boolAmount) internal {
        if (address(priceKeeper) == address(0) || priceKeeper.currentPrice() == 0) {
            return;
        }
        uint256 usdtValue = (boolAmount * priceKeeper.currentPrice()) / 1 ether;
        trackedBoolBalance[account] += boolAmount;
        trackedUsdtCost[account] += usdtValue;
    }

    function _decreaseCost(address account, uint256 boolAmount) internal {
        uint256 trackedBalance = trackedBoolBalance[account];
        if (trackedBalance == 0) {
            return;
        }
        uint256 costToRemove = boolAmount >= trackedBalance
            ? trackedUsdtCost[account]
            : (trackedUsdtCost[account] * boolAmount) / trackedBalance;
        trackedBoolBalance[account] = boolAmount >= trackedBalance ? 0 : trackedBalance - boolAmount;
        trackedUsdtCost[account] -= costToRemove;
    }

    function _takeProfitTax(address account, uint256 boolAmount) internal {
        if (address(priceKeeper) == address(0) || priceKeeper.currentPrice() == 0) {
            return;
        }

        uint256 trackedBalance = trackedBoolBalance[account];
        if (trackedBalance == 0) {
            return;
        }

        uint256 cost = boolAmount >= trackedBalance
            ? trackedUsdtCost[account]
            : (trackedUsdtCost[account] * boolAmount) / trackedBalance;
        uint256 proceeds = (boolAmount * priceKeeper.currentPrice()) / 1 ether;
        if (proceeds <= cost) {
            return;
        }

        uint256 profit = proceeds - cost;
        uint256 tax = (profit * PROFIT_TAX_BPS) / BPS;
        require(usdt.transferFrom(account, taxWallet, tax), "profit tax failed");
        profitLpUsdtAccrued += (profit * 2_000) / BPS;
        profitCommunityUsdtAccrued += (profit * 500) / BPS;
        emit ProfitTaxTaken(account, boolAmount, profit, tax);
    }
}

contract PurchaseManager is Ownable {
    uint8 public constant REWARD_REFERRAL = 1;
    uint256 public constant GENESIS_PRICE = 6_000 ether;
    uint256 public constant NODE_PRICE = 200 ether;
    uint256 public constant WHITELIST_BOOL_AMOUNT = 100 ether;
    uint256 public constant BPS = 10_000;

    IERC20 public immutable usdt;
    BOOLToken public immutable boolToken;
    ProjectNFT public immutable genesisNft;
    ProjectNFT public immutable nodeNft;
    ProjectNFT public immutable goldCardNft;
    PositionLedger public immutable ledger;
    RewardVault public immutable vault;
    address public treasury;

    mapping(address => address) public referrerOf;
    mapping(address => bool) public boughtNode;
    mapping(address => bool) public whitelistAvailable;
    mapping(address => bool) public whitelistUsed;
    mapping(address => uint256) public directNodeCount;
    mapping(address => uint256) public goldMinted;
    mapping(address => uint256) public personalPerformance;
    mapping(address => uint256) public teamPerformance;
    mapping(address => address[]) private directReferrals;

    event TreasurySet(address indexed treasury);
    event ReferrerBound(address indexed account, address indexed referrer);
    event GenesisBought(address indexed account, uint256 indexed tokenId, uint256 indexed positionId);
    event NodeBought(address indexed account, address indexed referrer, uint256 indexed tokenId, uint256 positionId);
    event StaticDeposited(address indexed account, address indexed referrer, uint256 amount, uint256 indexed positionId);
    event WhitelistBoolBought(address indexed account, uint256 amount);
    event GoldCardMinted(address indexed account, uint256 indexed tokenId);

    struct UserSnapshot {
        address referrer;
        bool boughtNode;
        bool whitelistAvailable;
        bool whitelistUsed;
        uint256 directReferralCount;
        uint256 directNodeCount;
        uint256 goldMinted;
        uint256 eligibleGoldCards;
        uint256 personalPerformance;
        uint256 teamPerformance;
        uint256 areaPerformance;
        uint256 directTotalPerformance;
        uint256 genesisBalance;
        uint256 nodeBalance;
        uint256 goldCardBalance;
    }

    struct TeamSnapshot {
        uint256 personalPerformance;
        uint256 userPerformance;
        uint256 areaPerformance;
        uint256 directTotalPerformance;
        uint256 directReferralCount;
        uint256 directNodeCount;
    }

    constructor(
        IERC20 usdt_,
        BOOLToken boolToken_,
        ProjectNFT genesisNft_,
        ProjectNFT nodeNft_,
        ProjectNFT goldCardNft_,
        PositionLedger ledger_,
        RewardVault vault_,
        address treasury_
    ) {
        require(treasury_ != address(0), "zero treasury");
        usdt = usdt_;
        boolToken = boolToken_;
        genesisNft = genesisNft_;
        nodeNft = nodeNft_;
        goldCardNft = goldCardNft_;
        ledger = ledger_;
        vault = vault_;
        treasury = treasury_;
    }

    function setTreasury(address treasury_) external onlyOwner {
        require(treasury_ != address(0), "zero treasury");
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    function buyGenesis(address referrer) external {
        _bindReferrer(msg.sender, referrer);
        require(usdt.transferFrom(msg.sender, treasury, GENESIS_PRICE), "pay failed");

        uint256 tokenId = genesisNft.mint(msg.sender);
        uint256 positionId = ledger.openPosition(
            msg.sender,
            PositionLedger.PositionKind.Genesis,
            tokenId,
            GENESIS_PRICE,
            3
        );
        _addPerformance(msg.sender, GENESIS_PRICE);

        emit GenesisBought(msg.sender, tokenId, positionId);
    }

    function buyNode(address referrer) external {
        require(!boughtNode[msg.sender], "node already bought");
        _bindReferrer(msg.sender, referrer);
        address boundReferrer = referrerOf[msg.sender];
        uint256 reward = _nodeReferralReward(boundReferrer);
        _collectPayment(msg.sender, NODE_PRICE, boundReferrer, reward);

        boughtNode[msg.sender] = true;
        whitelistAvailable[msg.sender] = true;
        if (boundReferrer != address(0)) {
            directNodeCount[boundReferrer] += 1;
        }

        uint256 tokenId = nodeNft.mint(msg.sender);
        uint256 positionId = ledger.openPosition(
            msg.sender,
            PositionLedger.PositionKind.Node,
            tokenId,
            NODE_PRICE,
            3
        );
        _addPerformance(msg.sender, NODE_PRICE);

        emit NodeBought(msg.sender, boundReferrer, tokenId, positionId);
    }

    function staticDeposit(uint256 amount, address referrer) external {
        require(amount > 0, "zero amount");
        _bindReferrer(msg.sender, referrer);
        address boundReferrer = referrerOf[msg.sender];
        uint256 reward = nodeNft.balanceOf(boundReferrer) > 0 ? (amount * 2_000) / BPS : 0;
        _collectPayment(msg.sender, amount, boundReferrer, reward);

        uint256 positionId = ledger.openPosition(
            msg.sender,
            PositionLedger.PositionKind.StaticDeposit,
            0,
            amount,
            2
        );
        _addPerformance(msg.sender, amount);

        emit StaticDeposited(msg.sender, boundReferrer, amount, positionId);
    }

    function whitelistBuyBool(uint256 amount) external {
        require(whitelistAvailable[msg.sender], "no quota");
        require(!whitelistUsed[msg.sender], "quota used");
        require(amount > 0 && amount <= WHITELIST_BOOL_AMOUNT, "bad amount");

        whitelistUsed[msg.sender] = true;
        require(usdt.transferFrom(msg.sender, treasury, amount), "pay failed");
        require(boolToken.transfer(msg.sender, amount), "bool transfer failed");
        boolToken.recordPurchaseCost(msg.sender, amount, amount);

        emit WhitelistBoolBought(msg.sender, amount);
    }

    function mintGoldCard() external {
        uint256 eligible = eligibleGoldCards(msg.sender);
        require(goldMinted[msg.sender] < eligible, "no quota");
        require(goldCardNft.totalSupply() < goldCardNft.maxSupply(), "gold sold out");

        goldMinted[msg.sender] += 1;
        uint256 tokenId = goldCardNft.mint(msg.sender);
        emit GoldCardMinted(msg.sender, tokenId);
    }

    function userSnapshot(address account) external view returns (UserSnapshot memory snapshot) {
        snapshot = UserSnapshot({
            referrer: referrerOf[account],
            boughtNode: boughtNode[account],
            whitelistAvailable: whitelistAvailable[account],
            whitelistUsed: whitelistUsed[account],
            directReferralCount: directReferrals[account].length,
            directNodeCount: directNodeCount[account],
            goldMinted: goldMinted[account],
            eligibleGoldCards: eligibleGoldCards(account),
            personalPerformance: personalPerformance[account],
            teamPerformance: teamPerformance[account],
            areaPerformance: areaPerformance(account),
            directTotalPerformance: directTotalPerformance(account),
            genesisBalance: genesisNft.balanceOf(account),
            nodeBalance: nodeNft.balanceOf(account),
            goldCardBalance: goldCardNft.balanceOf(account)
        });
    }

    function directReferralsOf(address account) external view returns (address[] memory) {
        return directReferrals[account];
    }

    function eligibleGoldCards(address account) public view returns (uint256) {
        return directNodeCount[account] / 30;
    }

    function areaPerformance(address account) public view returns (uint256) {
        return personalPerformance[account] + teamPerformance[account];
    }

    function directTotalPerformance(address account) public view returns (uint256 total) {
        address[] storage referrals = directReferrals[account];
        for (uint256 i = 0; i < referrals.length; i++) {
            total += areaPerformance(referrals[i]);
        }
    }

    function teamSnapshot(address account) external view returns (TeamSnapshot memory snapshot) {
        snapshot = TeamSnapshot({
            personalPerformance: personalPerformance[account],
            userPerformance: teamPerformance[account],
            areaPerformance: areaPerformance(account),
            directTotalPerformance: directTotalPerformance(account),
            directReferralCount: directReferrals[account].length,
            directNodeCount: directNodeCount[account]
        });
    }

    function _bindReferrer(address account, address referrer) internal {
        if (referrerOf[account] != address(0) || referrer == address(0) || referrer == account) {
            return;
        }
        referrerOf[account] = referrer;
        directReferrals[referrer].push(account);
        emit ReferrerBound(account, referrer);
    }

    function _nodeReferralReward(address referrer) internal view returns (uint256) {
        if (referrer == address(0)) {
            return 0;
        }
        if (genesisNft.balanceOf(referrer) > 0) {
            return (NODE_PRICE * 3_500) / BPS;
        }
        if (nodeNft.balanceOf(referrer) > 0) {
            return (NODE_PRICE * 2_000) / BPS;
        }
        return 0;
    }

    function _collectPayment(address payer, uint256 amount, address referrer, uint256 reward) internal {
        if (reward > 0) {
            require(usdt.transferFrom(payer, address(vault), reward), "reward pay failed");
            vault.credit(referrer, REWARD_REFERRAL, reward);
        }
        require(usdt.transferFrom(payer, treasury, amount - reward), "treasury pay failed");
    }

    function _addPerformance(address account, uint256 amount) internal {
        personalPerformance[account] += amount;
        address cursor = account;
        for (uint256 i = 0; i < 50; i++) {
            cursor = referrerOf[cursor];
            if (cursor == address(0)) {
                break;
            }
            teamPerformance[cursor] += amount;
        }
    }
}

contract RewardPool is Ownable {
    uint256 public constant BPS = 10_000;
    uint256 public constant HOURLY_DEFLATION_BPS = 25;
    uint256 public constant REWARD_PRECISION = 1e18;
    uint8 public constant CATEGORY_GENESIS = 2;
    uint8 public constant CATEGORY_LP = 3;
    uint8 public constant CATEGORY_GOLD = 4;

    RewardVault public immutable vault;
    ProjectNFT public genesisNft;
    ProjectNFT public goldCardNft;
    uint256 public internalBoolPool;
    uint256 public lastDeflationAt;
    uint256 public burnedBool;
    uint256 public genesisUsdtAccrued;
    uint256 public lpUsdtAccrued;
    uint256 public goldUsdtAccrued;
    uint256 public totalLpStake;
    uint256 public accGenesisUsdtPerNft;
    uint256 public accLpUsdtPerShare;
    uint256 public accGoldUsdtPerNft;

    mapping(address => uint256) public lpStakeOf;
    mapping(address => uint256) public genesisRewardDebt;
    mapping(address => uint256) public lpRewardDebt;
    mapping(address => uint256) public goldRewardDebt;

    event InternalBoolAdded(uint256 amount);
    event HourlyDeflationExecuted(uint256 boolAmount, uint256 usdtValue);
    event CategoryRewardCredited(address indexed account, uint8 indexed rewardType, uint256 amount);
    event NftContractsSet(address indexed genesisNft, address indexed goldCardNft);
    event LpStakeSet(address indexed account, uint256 amount);

    constructor(RewardVault vault_) {
        vault = vault_;
    }

    function setNftContracts(ProjectNFT genesisNft_, ProjectNFT goldCardNft_) external onlyOwner {
        require(address(genesisNft_) != address(0) && address(goldCardNft_) != address(0), "zero nft");
        genesisNft = genesisNft_;
        goldCardNft = goldCardNft_;
        emit NftContractsSet(address(genesisNft_), address(goldCardNft_));
    }

    function setLpStake(address account, uint256 amount) external onlyOwner {
        require(account != address(0), "zero account");
        _claimLpReward(account);

        uint256 current = lpStakeOf[account];
        totalLpStake = totalLpStake + amount - current;
        lpStakeOf[account] = amount;
        lpRewardDebt[account] = (amount * accLpUsdtPerShare) / REWARD_PRECISION;

        emit LpStakeSet(account, amount);
    }

    function addInternalBool(uint256 amount) external onlyOwner {
        require(amount > 0, "zero amount");
        internalBoolPool += amount;
        emit InternalBoolAdded(amount);
    }

    function executeHourlyDeflation(uint256 priceUsdtPerBool) external onlyOwner {
        require(priceUsdtPerBool > 0, "bad price");
        require(block.timestamp >= lastDeflationAt + 1 hours, "too early");
        uint256 boolAmount = (internalBoolPool * HOURLY_DEFLATION_BPS) / BPS;
        require(boolAmount > 0, "empty pool");

        lastDeflationAt = block.timestamp;
        internalBoolPool -= boolAmount;
        uint256 usdtValue = (boolAmount * priceUsdtPerBool) / 1 ether;

        uint256 genesisAmount = (usdtValue * 2_000) / BPS;
        uint256 lpAmount = (usdtValue * 5_000) / BPS;
        uint256 goldAmount = (usdtValue * 500) / BPS;

        genesisUsdtAccrued += genesisAmount;
        burnedBool += (boolAmount * 2_500) / BPS;
        lpUsdtAccrued += lpAmount;
        goldUsdtAccrued += goldAmount;

        if (address(genesisNft) != address(0) && genesisNft.totalSupply() > 0) {
            accGenesisUsdtPerNft += (genesisAmount * REWARD_PRECISION) / genesisNft.totalSupply();
        }
        if (totalLpStake > 0) {
            accLpUsdtPerShare += (lpAmount * REWARD_PRECISION) / totalLpStake;
        }
        if (address(goldCardNft) != address(0) && goldCardNft.totalSupply() > 0) {
            accGoldUsdtPerNft += (goldAmount * REWARD_PRECISION) / goldCardNft.totalSupply();
        }

        emit HourlyDeflationExecuted(boolAmount, usdtValue);
    }

    function creditCategoryReward(address account, uint8 rewardType, uint256 amount) external onlyOwner {
        require(
            rewardType == CATEGORY_GENESIS || rewardType == CATEGORY_LP || rewardType == CATEGORY_GOLD,
            "bad reward type"
        );
        if (rewardType == CATEGORY_GENESIS) {
            require(genesisUsdtAccrued >= amount, "not enough genesis");
            genesisUsdtAccrued -= amount;
        } else if (rewardType == CATEGORY_LP) {
            require(lpUsdtAccrued >= amount, "not enough lp");
            lpUsdtAccrued -= amount;
        } else {
            require(goldUsdtAccrued >= amount, "not enough gold");
            goldUsdtAccrued -= amount;
        }
        vault.credit(account, rewardType, amount);
        emit CategoryRewardCredited(account, rewardType, amount);
    }

    function pendingGenesisReward(address account) public view returns (uint256) {
        if (address(genesisNft) == address(0)) {
            return 0;
        }
        uint256 accumulated = (genesisNft.balanceOf(account) * accGenesisUsdtPerNft) / REWARD_PRECISION;
        uint256 debt = genesisRewardDebt[account];
        return accumulated > debt ? accumulated - debt : 0;
    }

    function pendingLpReward(address account) public view returns (uint256) {
        uint256 accumulated = (lpStakeOf[account] * accLpUsdtPerShare) / REWARD_PRECISION;
        uint256 debt = lpRewardDebt[account];
        return accumulated > debt ? accumulated - debt : 0;
    }

    function pendingGoldReward(address account) public view returns (uint256) {
        if (address(goldCardNft) == address(0)) {
            return 0;
        }
        uint256 accumulated = (goldCardNft.balanceOf(account) * accGoldUsdtPerNft) / REWARD_PRECISION;
        uint256 debt = goldRewardDebt[account];
        return accumulated > debt ? accumulated - debt : 0;
    }

    function claimGenesisReward() external {
        uint256 amount = pendingGenesisReward(msg.sender);
        require(amount > 0, "nothing to claim");
        require(genesisUsdtAccrued >= amount, "not enough genesis");
        genesisUsdtAccrued -= amount;
        genesisRewardDebt[msg.sender] =
            (genesisNft.balanceOf(msg.sender) * accGenesisUsdtPerNft) /
            REWARD_PRECISION;
        vault.credit(msg.sender, CATEGORY_GENESIS, amount);
        emit CategoryRewardCredited(msg.sender, CATEGORY_GENESIS, amount);
    }

    function claimLpReward() external {
        _claimLpReward(msg.sender);
    }

    function claimGoldReward() external {
        uint256 amount = pendingGoldReward(msg.sender);
        require(amount > 0, "nothing to claim");
        require(goldUsdtAccrued >= amount, "not enough gold");
        goldUsdtAccrued -= amount;
        goldRewardDebt[msg.sender] =
            (goldCardNft.balanceOf(msg.sender) * accGoldUsdtPerNft) /
            REWARD_PRECISION;
        vault.credit(msg.sender, CATEGORY_GOLD, amount);
        emit CategoryRewardCredited(msg.sender, CATEGORY_GOLD, amount);
    }

    function _claimLpReward(address account) internal {
        uint256 amount = pendingLpReward(account);
        if (amount == 0) {
            return;
        }
        require(lpUsdtAccrued >= amount, "not enough lp");
        lpUsdtAccrued -= amount;
        lpRewardDebt[account] = (lpStakeOf[account] * accLpUsdtPerShare) / REWARD_PRECISION;
        vault.credit(account, CATEGORY_LP, amount);
        emit CategoryRewardCredited(account, CATEGORY_LP, amount);
    }
}
