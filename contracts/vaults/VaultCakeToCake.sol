// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

/*
  ___                      _   _
 | _ )_  _ _ _  _ _ _  _  | | | |
 | _ \ || | ' \| ' \ || | |_| |_|
 |___/\_,_|_||_|_||_\_, | (_) (_)
                    |__/

*
* MIT License
* ===========
*
* Copyright (c) 2020 BunnyFinance
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in all
* copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
*/

import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";

import "../interfaces/IStrategy.sol";
import "../interfaces/IMasterChef.sol";
import "../interfaces/IBunnyMinter.sol";
import "./VaultController.sol";
import {PoolConstant} from "../library/PoolConstant.sol";


contract VaultCakeToCake is VaultController, IStrategy {
    using SafeBEP20 for IBEP20;
    using SafeMath for uint256;

    /* ========== CONSTANTS ============= */

    IBEP20 private constant CAKE = IBEP20(0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82);
    IMasterChef private constant CAKE_MASTER_CHEF = IMasterChef(0x73feaa1eE314F8c655E354234017bE2193C9E24E);

    /* ========== STATE VARIABLES ========== */

    uint public constant override pid = 0;//cake币在masterchef的pid是0
    //质押cake，获取cake 作为profit 及bunny
    PoolConstant.PoolTypes public constant override poolType = PoolConstant.PoolTypes.CakeStake;

    uint public totalShares;
    mapping (address => uint) private _shares;
    mapping (address => uint) private _principal;//本金
    mapping (address => uint) private _depositedAt;

    /* ========== INITIALIZER ========== */

    function initialize() external initializer {
        __VaultController_init(CAKE);
        CAKE.safeApprove(address(CAKE_MASTER_CHEF), uint(~0));

        setMinter(IBunnyMinter(0x0B4A714AAf59E46cb1900E3C031017Fd72667EfE));
    }

    /* ========== VIEW FUNCTIONS ========== */

    //返回cake余额
    function balance() override public view returns (uint) {
        //此合约地址的cake余额在masterchef那边
        (uint amount,) = CAKE_MASTER_CHEF.userInfo(pid, address(this));
        //masterchef那边的amount+此合约地址上拥有的cake
        return CAKE.balanceOf(address(this)).add(amount);
    }

    function balanceOf(address account) public view override returns(uint) {
        if (totalShares == 0) return 0;
        //按照share的百分比获取某个用户的balance，应该会变多
        return balance().mul(sharesOf(account)).div(totalShares);
    }

    function withdrawableBalanceOf(address account) public view override returns (uint) {
        return balanceOf(account);
    }

    function sharesOf(address account) public view override returns (uint) {
        return _shares[account];
    }

    function principalOf(address account) public view override returns (uint) {
        return _principal[account];
    }

    function earned(address account) public view override returns (uint) {
        if (balanceOf(account) >= principalOf(account)) {
            //减去本金额度
            return balanceOf(account).sub(principalOf(account));
        } else {
            return 0;
        }
    }

    function priceShare() external view override returns(uint) {
        if (totalShares == 0) return 1e18;
        //每一个share对于多少cake，每个share的价格，以cake数量计
        return balance().mul(1e18).div(totalShares);
    }

    function depositedAt(address account) external view override returns (uint) {
        return _depositedAt[account];
    }

    function rewardsToken() external view override returns (address) {
        //reward就是staking，即cake
        return address(_stakingToken);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */
    //deposit cake to this contract
    function deposit(uint _amount) public override {
        _deposit(_amount, msg.sender);

        if (isWhitelist(msg.sender) == false) {
            //不在白名单的用户记录原始的cake质押额度
            _principal[msg.sender] = _principal[msg.sender].add(_amount);
            //记录质押的时间
            _depositedAt[msg.sender] = block.timestamp;
        }
    }

    function depositAll() external override {
        deposit(CAKE.balanceOf(msg.sender));
    }

    function withdrawAll() external override {
        //按照share占比获取余额
        uint _withdraw = balanceOf(msg.sender);
        //总的share里面-用户的share
        totalShares = totalShares.sub(_shares[msg.sender]);
        delete _shares[msg.sender];
        //合约上的余额
        uint cakeBalance = CAKE.balanceOf(address(this));
        if (_withdraw > cakeBalance) {
            //从masterchef取出质押的cake
            CAKE_MASTER_CHEF.leaveStaking(_withdraw.sub(cakeBalance));
        }

        uint principal = _principal[msg.sender];
        uint depositTimestamp = _depositedAt[msg.sender];
        delete _principal[msg.sender];
        delete _depositedAt[msg.sender];

        uint withdrawalFee;
        if (canMint() && _withdraw > principal) {
            //按照share计算的余额-原始的质押额度，即为收益，收益为cake
            uint profit = _withdraw.sub(principal);
            withdrawalFee = _minter.withdrawalFee(_withdraw, depositTimestamp);
            uint performanceFee = _minter.performanceFee(profit);

            //传入cake数量，swap转成wbnb bunny币，质押到wbnb bunny币pool增加流动性，产生lp币，转入bunnypool作为reward，performanceFee的30% mint bunny币转给用户
            _minter.mintFor(address(CAKE), withdrawalFee, performanceFee, msg.sender, depositTimestamp);
            emit ProfitPaid(msg.sender, profit, performanceFee);

            //除去两个费用，将剩余的cake转给用户
            _withdraw = _withdraw.sub(withdrawalFee).sub(performanceFee);
        }

        CAKE.safeTransfer(msg.sender, _withdraw);
        emit Withdrawn(msg.sender, _withdraw, withdrawalFee);

        harvest();
    }

    function harvest() public override {
        //从masterchef收割到收益，然后再将受益质押过去
        CAKE_MASTER_CHEF.leaveStaking(0);
        //此合约上的cake总量
        uint cakeAmount = CAKE.balanceOf(address(this));
        emit Harvested(cakeAmount);
        //将此合约上的cake质押到masterchef
        CAKE_MASTER_CHEF.enterStaking(cakeAmount);
    }

    function withdraw(uint256 shares) external override onlyWhitelisted {
        uint _withdraw = balance().mul(shares).div(totalShares);
        totalShares = totalShares.sub(shares);
        _shares[msg.sender] = _shares[msg.sender].sub(shares);

        uint cakeBalance = CAKE.balanceOf(address(this));
        if (_withdraw > cakeBalance) {
            CAKE_MASTER_CHEF.leaveStaking(_withdraw.sub(cakeBalance));
        }
        CAKE.safeTransfer(msg.sender, _withdraw);
        emit Withdrawn(msg.sender, _withdraw, 0);

        harvest();
    }

    function getReward() external override {
        revert("N/A");
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function _deposit(uint _amount, address _to) private notPaused {
        //目前池子里的cake数量
        uint _pool = balance();
        //用户转cake到此合约上
        CAKE.safeTransferFrom(msg.sender, address(this), _amount);
        uint shares = 0;
        if (totalShares == 0) {
            //初始share即为用户的amount
            shares = _amount;
        } else {
            //share为totalShares*amount在pool里的cake的占比
            shares = (_amount.mul(totalShares)).div(_pool);
        }

        totalShares = totalShares.add(shares);
        _shares[_to] = _shares[_to].add(shares);
        //将新质押的cake质押到masterchef
        CAKE_MASTER_CHEF.enterStaking(_amount);
        emit Deposited(msg.sender, _amount);
        //收割一下，再质押
        harvest();
    }
}
