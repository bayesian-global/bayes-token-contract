// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.16;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract BayeToken is ERC20,ERC20Burnable,Ownable{
    uint256 public constant MAX_SUPPLY = 3_141_590_000e18;
    
    constructor() ERC20("Baye Token", "BYT") {
        mint(_msgSender(),1000000*1e18);
    }
    
    function mint(address to, uint256 amount) public onlyOwner {
        require(totalSupply() + amount <= MAX_SUPPLY,"out of bounds");
        _mint(to, amount);
    }

    function decimals() public view virtual override returns (uint8) {
        return 18;
    }
}