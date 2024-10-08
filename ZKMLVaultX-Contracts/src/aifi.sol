// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import '@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol';
import '@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol';
import {BaseUltraVerifier, UltraVerifier} from "./verifier.sol";
import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

contract Aifi is Ownable{

    struct MLModel{
        address payable deployer;
        address token;
        uint256 cumulativeDeposit;
        uint256 tradedBalance;
        uint256 startedTimestamp;
        bool onTrade;
    }

    struct Vault{
        address creator;
        uint256[] modelKeys;
        mapping (uint256 => uint256) weights;
        mapping (uint256 => uint256) tokenAmounts;
        uint256 amount;
        uint256 timestampCreated;
    }


    mapping (uint256=>MLModel) models;
    uint256 public modelCount;

    mapping (uint256 => Vault) vaults;
    uint256 public vaultCount;

    IERC20 public immutable usdcToken;
    ISwapRouter public immutable swapRouter;
    UltraVerifier proofVerifier;
    IPyth pyth;

    modifier onlyDeployer(uint model) {
        require(models[model].deployer == msg.sender, "Only deployer can submit proofs");
        _;
    }

    modifier onlyVaultOwner(uint vaultId) {
        require(vaults[vaultId].creator == msg.sender, "Only deployer can submit proofs");
        _;
    }

    constructor(address usdc, address router, address pythAddress)Ownable(){
        usdcToken = IERC20(usdc);
        swapRouter = ISwapRouter(router);
        proofVerifier = new UltraVerifier();
        pyth = IPyth(pythAddress);
    }

    function addModel(address token) external{
        MLModel memory newModel = MLModel({deployer: payable(msg.sender), token: token, cumulativeDeposit: 0, tradedBalance:0, startedTimestamp:0, onTrade: false});
        models[modelCount] = newModel;
        modelCount++;
    }


    function createVault(uint256[] memory mlmodels, uint256[] memory weights, uint256 amount) external{
        Vault storage newVault = vaults[vaultCount];
        newVault.creator = msg.sender;
        for(uint i=0; i<mlmodels.length; i++){
            newVault.modelKeys.push(mlmodels[i]);
            newVault.weights[mlmodels[i]] = weights[i];
        }
        require(usdcToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        for(uint i=0; i<mlmodels.length; i++){
            newVault.tokenAmounts[mlmodels[i]] = amount*weights[i]/100;
            models[mlmodels[i]].cumulativeDeposit += amount*weights[i]/100;
            if(models[mlmodels[i]].startedTimestamp == 0){
                models[mlmodels[i]].startedTimestamp = block.timestamp;
            }
        }
        newVault.timestampCreated = block.timestamp;
        vaultCount++;
    }

    function closeVault(uint256 vaultId) external onlyVaultOwner(vaultId){
        uint256 timeDiff = block.timestamp - vaults[vaultId].timestampCreated;
        for(uint256 i=0; i<vaults[vaultId].modelKeys.length; i++){
            require(!models[vaults[vaultId].modelKeys[i]].onTrade, "Model is currently in a trade");
            uint256 diff = block.timestamp - models[vaults[vaultId].modelKeys[i]].startedTimestamp;
            int256 balance = int256(models[vaults[vaultId].modelKeys[i]].cumulativeDeposit) - int256(models[vaults[vaultId].modelKeys[i]].tradedBalance);
            uint256 amount = uint256(((balance*int256(timeDiff))/int256(diff))+int256(vaults[vaultId].tokenAmounts[vaults[vaultId].modelKeys[i]]));
            models[vaults[vaultId].modelKeys[i]].cumulativeDeposit -= amount;
        }
    }

    function submitProof(uint256 model, bytes32[] memory pubInputs, bytes memory proof) external onlyDeployer(model){
        //If proof if verified
        require(proofVerifier.verify(proof, pubInputs), "Invalid proof");
        if(models[model].onTrade){
            IERC20(models[model].token).approve(address(swapRouter), IERC20(models[model].token).balanceOf(address(this)));
            ISwapRouter.ExactInputSingleParams memory params = 
                ISwapRouter.ExactInputSingleParams({
                tokenIn: models[model].token,
                tokenOut: address(usdcToken),
                fee: 3000,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: IERC20(models[model].token).balanceOf(address(this)),
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });
            uint256 amountOut = swapRouter.exactInputSingle(params);
            models[model].cumulativeDeposit = uint256(int256(models[model].cumulativeDeposit) + int256(amountOut)-int256(models[model].tradedBalance));
        }else{
            IERC20(address(usdcToken)).approve(address(swapRouter), models[model].cumulativeDeposit);
            ISwapRouter.ExactInputSingleParams memory params = 
                ISwapRouter.ExactInputSingleParams({
                tokenIn: address(usdcToken),
                tokenOut: models[model].token,
                fee: 3000,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: models[model].cumulativeDeposit,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });
            uint256 amountOut = swapRouter.exactInputSingle(params);
            models[model].tradedBalance = amountOut;
        }
    }

    
    function verify(bytes32[] memory pubInputs, bytes memory proof) external view{
        require(proofVerifier.verify(proof, pubInputs), "Invalid proof");
    }

    function getPrice(address token) internal returns(PythStructs.Price memory){
        if(token == address(0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14)){
            bytes32 priceFeedId = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace; // ETH/USD
            PythStructs.Price memory price = pyth.getPriceNoOlderThan(priceFeedId, 60);
            return price;
        }else if(token == address(0xFF34B3d4Aee8ddCd6F9AFFFB6Fe49bD371b8a357)){
            bytes32 priceFeedId = 0xb0948a5e5313200c632b51bb5ca32f6de0d36e9950a942d19751e833f70dabfd; // ETH/USD
            PythStructs.Price memory price = pyth.getPriceNoOlderThan(priceFeedId, 60);
            return price;
        }
    }

}
