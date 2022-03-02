pragma solidity >=0.8.0 <0.9.0;
//SPDX-License-Identifier: MIT

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract _AKITA is ERC20 {
    constructor() ERC20("_AKITA", "_AKITA") {
        uint256 _amount = 1e11 * 1e18; 
        _mint(msg.sender, _amount);
    }

    function mint(address recepient, uint256 amount) external {
        _mint(recepient, amount);
    } 
}

contract _WAVAX is ERC20 {
    constructor() ERC20("_WAVAX", "_WAVAX") {
        uint256 _amount = 1e11 * 1e18; 
        _mint(msg.sender, _amount);
    }
}

contract _ANOTHERRESERVE is ERC20 {
    constructor() ERC20("_ANOTHERRESERVE", "_ANOTHERRESERVE") {
        uint256 _amount = 1e11 * 1e18; 
        _mint(msg.sender, _amount);
    }
}

contract _WAVAXAKITA is ERC20 {
    constructor() ERC20("_WAVAXAKITA", "_WAVAXAKITA") {
        uint256 _amount = 1e11 * 1e18; 
        _mint(msg.sender, _amount);
    }
}

contract _SGAKITA is ERC20 {
    constructor() ERC20("_SGAKITA", "_SGAKITA") {
      uint256 _amount = 1e11 * 1e18; 
      _mint(msg.sender, _amount);
  }
}