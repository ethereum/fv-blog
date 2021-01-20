---
layout: post
published: true
title: Automated Synthesis of External Unknown Functions
date: '2021-01-18'
author: Leo Alt
category: 'Research & Development'
---

The [SMTChecker](https://docs.soliditylang.org/en/v0.8.0/security-considerations.html#formal-verification),
a formal verification module built-in the Solidity compiler, received a lot of
improvements in 2020. Many improvements are related to
Solidity's language features, such as structs, ABI, hash and math functions,
and other important features that were unsupported.
When running the tool, the user now has more control and is able to set a
timeout per query and choose engines separately between
[BMC and CHC](https://docs.soliditylang.org/en/v0.8.0/security-considerations.html#model-checking-engines).
The CHC engine encodes Solidity code as [Constrained Horn Clauses](https://en.wikipedia.org/wiki/Horn_clause)
and is often able to
[handle loops and contract invariants](https://medium.com/@leonardoalt/smtchecker-toward-completeness-1a99c02e0133).
The internals of the CHC engine will be detailed in an upcoming series of
posts.
CHC has been extended to analyze external calls to unknown code and report
counterexamples including transaction traces, which are the focus of this post.

## Counterexamples and Transaction Traces

The CHC engine has been able to tell whether a property holds or not for a
while, but counterexample reporting was only added recently.  The
counterexample attempts to give concrete values for state, input and output
variables.  It works well in general, but might fail sometimes for non-value
types due to their complexity.  The user also receives a full transaction trace
that leads to the property being violated.

Consider the Solidity sample below:
```solidity
//SPDX-License-Identifier: GPL-v3
pragma solidity ^0.8.0;
pragma experimental SMTChecker;

contract Test {
	function max(uint[] memory _a) public pure returns (uint) {
		require(_a.length > 5);
		uint m = 0;
		for (uint i = 0; i < _a.length; ++i)
			if (_a[i] > m)
				m = _a[i];

		for (uint i = 0; i < _a.length; ++i)
			assert(m > _a[i]);

		return m;
	}
}
```

The function takes an array of length at least 6, and computes the maximum
element of the array.  After that, it asserts that the previously found max
element `m` is greater than all the elements of the array, which is what the
SMTChecker will try to prove.  The property is almost true:

```sh
$ solc max.sol --model-checker-engine chc

Warning: CHC: Assertion violation happens here.
Counterexample:

_a = [0, 0, 0, 0, 0, 0]

Transaction trace:
Test.constructor()
Test.max([0, 0, 0, 0, 0, 0])
  --> max.sol:14:4:
   |
14 | 			assert(m > _a[i]);
   | 			^^^^^^^^^^^^^^^^^
```

The SMTChecker gives us a pretty simple counterexample, an array full of
zeroes. Our property missed the fact that the max element is also in the array,
and therefore cannot be greater than itself. The correct property should be
`assert(m >= _a[i]);`. After fixing the property, we're able to prove it, shown
by the absence of a warning from the tool.
Note that in the same run the SMTChecker also proved that none of the `++i` can
overflow.

---

The following simplified Crowdsale snippet from the previous blog post requires
a few more transactions to violate the assertion.

```solidity
//SPDX-License-Identifier: GPL-v3
pragma solidity ^0.8.0;
pragma experimental SMTChecker;

contract SimpleCrowdsale {
	enum State { INIT, STARTED, FINISHED }
	State state = State.INIT;

	uint public weiRaised;
	uint public cap;

	constructor(uint _cap) {
		setCap(_cap);
	}

	function setCap(uint _cap) internal {
		require(state == State.INIT);
		require(_cap > 0);
		cap = _cap;
		state = State.STARTED;
	}

	receive() external payable {
		require(state == State.STARTED);
		require(msg.value > 0);
		uint newWeiRaised = weiRaised + msg.value;
		require(newWeiRaised <= cap);
		weiRaised = cap;
	}

	function finalize() public {
		require(state == State.STARTED);
		assert(weiRaised < cap);
		state = State.FINISHED;
	}
}
```

The counterexample is:

```sh
$ solc crowdsale.sol --model-checker-engine chc

Warning: CHC: Assertion violation happens here.
Counterexample:
state = 1, weiRaised = 1, cap = 1

Transaction trace:
SimpleCrowdsale.constructor(1)
State: state = 1, weiRaised = 0, cap = 1
SimpleCrowdsale.receive()
State: state = 1, weiRaised = 1, cap = 1
SimpleCrowdsale.finalize()
  --> crowdsale.sol:33:3:
   |
33 | 		assert(weiRaised < cap);
   | 		^^^^^^^^^^^^^^^^^^^^^^^
```

The counterexample shows that after deployment, the assertion violation can be
reached with 2 transactions. The correct property is `assert(weiRaised <= cap);`.

## External Calls to Unknown Code

External calls most of the time cannot be resolved at compile time. That is
only possible for external calls to the same contract (`this`) or to contracts
that were deployed by the caller.  This presents a new challenge in proving
contract invariants: they must hold even if the contract makes external calls
to unknown code that can do anything! This includes an unbounded number of
potential reentrant calls to the original contract, and calls to other
contracts.

The `mutex` example below asserts the property that state variable `x` cannot
be modified inside function `run`. Function `run` does not change `x` directly,
but it performs an external call to unknown code which can, for example, call
contract `Mutex` back, trying to change `x` via `Mutex.set`.
A precise analysis of this case requires not only functional knowledge about
`Mutex.set`, but also global knowledge about `Mutex`'s behavior in the case of
any number of reentrant calls, in any order.

```solidity
//SPDX-License-Identifier: GPL-v3
pragma solidity ^0.8.0;
pragma experimental SMTChecker;

interface Unknown {
	function run() external;
}

contract Mutex {
	uint x;
	bool lock;

	Unknown immutable unknown;

	constructor(Unknown _u) {
		require(address(_u) != address(0));
		unknown = _u;
	}

	modifier mutex {
		require(!lock);
		lock = true;
		_;
		lock = false;
	}

	function set(uint _x) mutex public {
		x = _x;
	}

	function run() mutex public {
		uint xPre = x;
		unknown.run();
		assert(xPre == x);
	}
}
```

[Spacer](https://spacer.bitbucket.io/),
the Horn solver used by the CHC engine, automatically infers the inductive
invariant `lockPre => lockPost && lockPre => (xPost = xPre)` for that specific
external call, that is, it learns that

- if `lock = true` before the call, it must also be `true` after the call.
- if `lock = true` before the call, `x` cannot be modified by reentrant calls.

From the local context it knows that `lock = true` before the call.  Therefore,
it must be true that **no reentrant call** can modify `x` in the example above,
and the property is correct.

Another important feature is the one that names this post. In case *it is*
possible to violate the assertion, the solver synthesizes the behavior of the
externally called unknown code, telling us exactly what needs to be done to
break the property. If `Mutex.run` is not guarded by `lock`, the SMTChecker
reports

```sh
Warning: CHC: Assertion violation happens here.
Counterexample:
x = 1, lock = false, unknown = 1

Transaction trace:
Mutex.constructor(1)
State: x = 0, lock = false, unknown = 1
Mutex.run()
    unknown.run() -- untrusted external call, synthesized as:
        Mutex.set(1) -- reentrant call
  --> mutex.sol:34:3:
   |
34 | 		assert(xPre == x);
   | 		^^^^^^^^^^^^^^^^^
```

Here the solver finds out that all the unknown code needs to do is call
`Mutex.set` once, and the property will be violated at the end of `Mutex.run`.

Note that `unknown = 1` means the address of the `Unknown` contract called by
`Mutex`, where the actual address of the deployed contract doesn't really
matter, as long as it implements a function `run()` that calls `Mutex.set(1)`.

---

The following sample contract shows the counterexample report in case the external
unknown function needs to make multiple calls:

```solidity
//SPDX-License-Identifier: GPL-v3
pragma solidity ^0.8.0;
pragma experimental SMTChecker;

interface Unknown {
	function run() external;
}

contract Test {
	uint x;
	uint y;

	Unknown immutable unknown;

	constructor(Unknown _u) {
		require(address(_u) != address(0));
		unknown = _u;
	}

	function incX() public { ++x; }
	function incY() public { ++y; }

	function f() public {
		unknown.run();
		assert(x < 3 || y < 1);
	}
}
```

The property is false, and the SMTChecker reports:

```sh
$ solc external_inc.sol --model-checker-engine chc

Warning: CHC: Assertion violation happens here.
Counterexample:
x = 3, y = 1, unknown = 1

Transaction trace:
Test.constructor(1)
State: x = 0, y = 0, unknown = 1
Test.f()
    unknown.run() -- untrusted external call, synthesized as:
        Test.incX() -- reentrant call
        Test.incX() -- reentrant call
        Test.incX() -- reentrant call
        Test.incY() -- reentrant call
  --> external_inc.sol:25:3:
   |
25 | 		assert(x < 3 || y < 1);
   | 		^^^^^^^^^^^^^^^^^^^^^^
```

---

We can naturally try to apply this feature on code that might
be vulnerable to reentrancy. For example, take the following simplified/modified
implementation of a [ERC777](https://eips.ethereum.org/EIPS/eip-777) token:

```solidity
//SPDX-License-Identifier: GPL-v3
pragma solidity ^0.8.0;
pragma experimental SMTChecker;

interface IERC777Recipient {
	function tokensReceived(
		address from,
		address to,
		uint256 amount
	) external;
}

interface IERC777Sender {
	function tokensToSend(
		address from,
		address to,
		uint256 amount
	) external;
}

contract ERC777 {
	mapping (address => uint256) public balanceOf;
	uint public totalSupply;

	function deposit(uint _amount) public payable {
		require(_amount == msg.value);
		require(msg.value > 0);
		balanceOf[msg.sender] += msg.value;
		totalSupply += msg.value;
	}

	function withdraw(uint _amount) public {
		require(_amount > 0 && _amount <= balanceOf[msg.sender]);
		payable(msg.sender).transfer(_amount);
		balanceOf[msg.sender] -= _amount;
		totalSupply -= _amount;
	}

	function transfer(address _to, uint _amount) public {
		require(msg.sender != _to);
		require(_amount > 0);
		require(balanceOf[msg.sender] >= _amount);
		uint preSupply = totalSupply;

		balanceOf[msg.sender] -= _amount;
		balanceOf[_to] += _amount;

		IERC777Sender(msg.sender).tokensToSend(msg.sender, _to, _amount);
		IERC777Recipient(_to).tokensReceived(msg.sender, _to, _amount);

		assert(totalSupply == preSupply);
	}
}
```

A common property in token contracts is that the `totalSupply` does not change
between the beginning and the end of an atomic transfer, represented by the
`assert` at the last line of `ERC777.transfer`.
When trying to prove the property, we learn that:

```sh
Warning: CHC: Assertion violation happens here.
Counterexample:
totalSupply = 2
_to = 8944
_amount = 2

Transaction trace:
ERC777.constructor()
State: totalSupply = 0
ERC777.deposit(591)
State: totalSupply = 591
ERC777.transfer(8944, 2)
    IERC777Sender(msg.sender).tokensToSend(msg.sender, _to, _amount) -- untrusted external call, synthesized as:
        ERC777.withdraw(589) -- reentrant call
    IERC777Recipient(_to).tokensReceived(msg.sender, _to, _amount) -- untrusted external call
  --> erc777.sol:51:3:
   |
51 | 		assert(totalSupply == preSupply);
   | 		^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
```

ERC777 specifies hooks that call back to both sender and recipients of a
transfer. These hooks may perform reentrant calls to the ERC777 tokens, leading
to the property begin violated at the end of the transfer.
If this property is desired, `mutex` can be used to guarantee no reentrancy.

## Future work

Automatic synthesis of malicious code is extremely challenging and therefore an
exciting milestone. This feature works with the assumption that we can never
trust code called externally, since at compile time we do not know what exactly
will be deployed as the called contract.
A complementary feature that seems useful is to optionally handle externally
called code as trusted, if an implementation is available at compile time.
This provides the possibility of proving under which implementations of a
certain interface your properties hold.

Besides that, we are continuously working on increasing language coverage,
decreasing false positives, and improving solving performance.

In the upcoming weeks I also intend to release a series of posts detailing the
internals of the CHC engine, which I find exciting and I hope you will too!

## Acknowledgments

We thank Martin Blicha and Antti Hyvärinen from Università della Svizzera
italiana for their contributions to the SMTChecker's CHC engine's theory and
code, as part of our ongoing research collaboration on formal verification of
smart contracts.
