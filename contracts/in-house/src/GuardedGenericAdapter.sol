/**
 * Guarded generic vault implementation.
 */

pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;


import "@enzyme/release/extensions/integration-manager/integrations/utils/AdapterBase.sol";
import "@enzyme/release/core/fund/vault/VaultLib.sol";
//import "@enzyme/release/core/fund/vault/VaultLib.sol";
//import "@enzyme/release/core/fund/vault/IVault.sol";
//import "@enzyme/release/extensions/integration-manager/integrations/utils/AdapterBase.sol";
//import "@enzyme/release/extensions/integration-manager/integrations/utils/AdapterBase.sol";
//import "@enzyme/contracts/release/extensions/integration-manager/integrations/utils/AdapterBase.sol";

//interface IVault {
    // Circular imports in Enzyme
//}

interface IGuard {
    function validateCall(address sender, address target, bytes calldata callDataWithSelector) external;
}

/**
 * A generic adapter for Enzyme vault with our own guard mechanism.
 *
 * - Guard checks the asset manager cannot perform actions
 *   that are not allowed (withdraw, trade wrong tokens)
 *
 * - Governance address can still perform hese actions
 *
 * - Adapter is associated with a specific vault
 *
 */
contract GuardedGenericAdapter is AdapterBase {

    // The vault this adapter is associated with.
    //
    // Enzyme allows adapters to serve multiple vaults,
    // but we limit to a specific vault to reduce the security
    // footprint.
    //
    IVault public vault;

    // Guard implementation associated with this vault
    IGuard public guard;

    // Tell enzyme what is our selector when we call this adapter
    bytes4 public constant EXECUTE_CALLS_SELECTOR = bytes4(
        keccak256("executeCalls(address,bytes,bytes)")
    );

    constructor(
        address _integrationManager,
        IVault _vault,
        IGuard _guard
    ) public AdapterBase(_integrationManager) {
        //vault = _whitelistedVault;
        // Check the vault is proper vault contract
        // Only if the crappy Solidity development tooling had interfaces people use
        vault = _vault;
        // Sanity check for smart contract integration - mainly checks vault providers getCreator() as an interface check
        require(vault.getCreator() != 0x0000000000000000000000000000000000000000, "Encountered funny vault");
        guard = _guard;
    }

    // EXTERNAL FUNCTIONS

    /// @notice Executes a sequence of calls
    /// @param _vaultProxy The VaultProxy of the calling fund
    /// @param _actionData Data specific to this action
    function executeCalls(
        address _vaultProxy,
        bytes calldata _actionData,
        bytes calldata
    )
        external
        onlyIntegrationManager
        postActionIncomingAssetsTransferHandler(_vaultProxy, _actionData)
        postActionSpendAssetsTransferHandler(_vaultProxy, _actionData)
    {
        require(_vaultProxy == address(vault), "Only calls from the whitelisted vault are allowed");

        (, , , , bytes memory externalCallsData) = __decodeCallArgs(_actionData);

        (address[] memory contracts, bytes[] memory callsData) = __decodeExternalCallsData(
            externalCallsData
        );

        for (uint256 i; i < contracts.length; i++) {
            callGuarded(contracts[i], callsData[i]);
        }
    }

    /**
     * Checks if the asset manager is allowed to do this action with the guard smart contract.
     *
     * Then perform the action. If the action reverts, unwind the execution.
     */
    function callGuarded(address contractAddress, bytes memory callData) internal {
        // TODO: Looks like currently Enzyme does not pass the asset manager
        // address that initiated the call, so we just use generic adapter address
        // as the asset manager
        guard.validateCall(address(vault), contractAddress, callData);

        (bool success, bytes memory returnData) = contractAddress.call(callData);

        if(!success) {
            assembly{
                let revertStringLength := mload(returnData)
                let revertStringPtr := add(returnData, 0x20)
                revert(revertStringPtr, revertStringLength)
            }
        }
        // require(success, string(returnData));
    }

    /// @notice Parses the expected assets in a particular action
    /// @param _selector The function selector for the callOnIntegration
    /// @param _actionData Data specific to this action
    /// @return spendAssetsHandleType_ A type that dictates how to handle granting
    /// the adapter access to spend assets (hardcoded to `Transfer`)
    /// @return spendAssets_ The assets to spend in the call
    /// @return spendAssetAmounts_ The max asset amounts to spend in the call
    /// @return incomingAssets_ The assets to receive in the call
    /// @return minIncomingAssetAmounts_ The min asset amounts to receive in the call
    function parseAssetsForAction(
        address,
        bytes4 _selector,
        bytes calldata _actionData
    )
        external
        view
        override
        returns (
            IIntegrationManager.SpendAssetsHandleType spendAssetsHandleType_,
            address[] memory spendAssets_,
            uint256[] memory spendAssetAmounts_,
            address[] memory incomingAssets_,
            uint256[] memory minIncomingAssetAmounts_
        )
    {
        require(_selector == EXECUTE_CALLS_SELECTOR, "parseAssetsForAction: _selector invalid");

        (
            incomingAssets_,
            minIncomingAssetAmounts_,
            spendAssets_,
            spendAssetAmounts_,

        ) = __decodeCallArgs(_actionData);

        return (
            IIntegrationManager.SpendAssetsHandleType.Transfer,
            spendAssets_,
            spendAssetAmounts_,
            incomingAssets_,
            minIncomingAssetAmounts_
        );
    }

    /// @dev Helper to decode the encoded callOnIntegration call arguments
    function __decodeCallArgs(bytes calldata _actionData)
        private
        pure
        returns (
            address[] memory incomingAssets_,
            uint256[] memory minIncomingAssetsAmounts_,
            address[] memory spendAssets_,
            uint256[] memory spendAssetAmounts_,
            bytes memory externalCallsData_
        )
    {
        return abi.decode(_actionData, (address[], uint256[], address[], uint256[], bytes));
    }

    /// @dev Helper to decode the stack of external contract calls
    function __decodeExternalCallsData(bytes memory _externalCallsData)
        private
        pure
        returns (address[] memory contracts_, bytes[] memory callsData_)
    {
        (contracts_, callsData_) = abi.decode(_externalCallsData, (address[], bytes[]));
        require(contracts_.length == callsData_.length, "Unequal external calls arrays lengths");
        return (contracts_, callsData_);
    }
}
