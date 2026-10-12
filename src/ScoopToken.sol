// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Scoop (SCOOP)
/// @notice A fixed-supply ERC-20. The whole supply of 1,000,000,000 SCOOP (18 decimals) is minted
/// once, in the constructor, to the deployer. There is no owner, no minter, no pause, no blocklist
/// and no fee: after construction the contract has no privileged functions at all, and the supply
/// can never grow.
/// @dev Self-contained on purpose. The launch hashes and deploys the bytecode exactly as built, so
/// the token depends on no library code that could leave a link placeholder, and it has no
/// constructor arguments. `msg.sender` at construction is the launch factory, which pays the whole
/// supply out (swarm share, pool seed, remainder); for a manual deployment it is whoever deploys.
contract ScoopToken {
    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // Metadata
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice ERC-20 name.
    string public constant name = "Scoop";
    /// @notice ERC-20 symbol.
    string public constant symbol = "SCOOP";
    /// @notice ERC-20 decimals.
    uint8 public constant decimals = 18;
    /// @notice The one and only supply, in minor units: 1,000,000,000 * 10^18.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Total number of tokens in existence. Fixed at construction.
    uint256 public immutable totalSupply;

    /// @notice Balance of each account.
    mapping(address account => uint256) public balanceOf;

    /// @notice Remaining allowance an owner has granted a spender.
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // Events (ERC-20)
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice A transfer or approval named the zero address where a real account is required.
    error ZeroAddress();
    /// @notice `sender` tried to move `needed` but holds only `balance`.
    error InsufficientBalance(address sender, uint256 balance, uint256 needed);
    /// @notice `spender` tried to move `needed` on behalf of an owner who allowed only `allowed`.
    error InsufficientAllowance(address spender, uint256 allowed, uint256 needed);

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // Construction
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Mints the entire fixed supply to the deployer (`msg.sender`). Takes no arguments and
    /// calls no other contract, so it deploys on an empty chain.
    constructor() {
        totalSupply = INITIAL_SUPPLY;
        balanceOf[msg.sender] = INITIAL_SUPPLY;
        emit Transfer(address(0), msg.sender, INITIAL_SUPPLY);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // ERC-20
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Moves `amount` from the caller to `to`.
    /// @dev Reverts on a zero recipient or an insufficient balance. Always moves exactly `amount`.
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice Lets `spender` move up to `amount` of the caller's tokens. Overwrites any prior
    /// allowance; use `increaseAllowance` / `decreaseAllowance` to adjust without a race.
    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    /// @notice Moves `amount` from `from` to `to` using the caller's allowance.
    /// @dev An allowance of `type(uint256).max` is treated as unlimited and is not decremented.
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    /// @notice Raises the caller's allowance for `spender` by `addedValue`.
    function increaseAllowance(address spender, uint256 addedValue) external returns (bool) {
        _approve(msg.sender, spender, allowance[msg.sender][spender] + addedValue);
        return true;
    }

    /// @notice Lowers the caller's allowance for `spender` by `subtractedValue`.
    /// @dev Reverts rather than underflowing if the current allowance is smaller.
    function decreaseAllowance(address spender, uint256 subtractedValue) external returns (bool) {
        uint256 current = allowance[msg.sender][spender];
        if (current < subtractedValue) revert InsufficientAllowance(spender, current, subtractedValue);
        _approve(msg.sender, spender, current - subtractedValue);
        return true;
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // Internals
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0)) revert ZeroAddress();
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < amount) revert InsufficientBalance(from, fromBalance, amount);
        unchecked {
            // fromBalance >= amount was just checked, and the sum of all balances is the fixed
            // totalSupply, so the recipient's balance cannot overflow.
            balanceOf[from] = fromBalance - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _approve(address owner, address spender, uint256 amount) private {
        if (spender == address(0)) revert ZeroAddress();
        allowance[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _spendAllowance(address owner, address spender, uint256 amount) private {
        uint256 current = allowance[owner][spender];
        if (current == type(uint256).max) return;
        if (current < amount) revert InsufficientAllowance(spender, current, amount);
        unchecked {
            allowance[owner][spender] = current - amount;
        }
        emit Approval(owner, spender, current - amount);
    }
}
