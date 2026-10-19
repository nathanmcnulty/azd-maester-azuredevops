# Authentication context during setup

Azure CLI (`az`), Azure Developer CLI (`azd`), and Az PowerShell maintain
separate authentication state. A successful Azure CLI login alone does not
establish that Azure Developer CLI has a usable token for provisioning.

Post-provision setup requests an Azure CLI management token for the selected
subscription and refreshes Az PowerShell with it when available. Otherwise,
setup retains a matching cached Az context or uses the normal interactive
Az PowerShell login. Before discovering deployment targets, setup verifies
that the resulting Az context matches the selected subscription and tenant.
An explicit tenant is required before ARM validation; setup does not infer an intended tenant from an ambient session. An unconfirmed context stops setup.

This check does not synchronize the tools' credential stores or resolve an
expired token in an earlier Azure Developer CLI provisioning stage. If that
stage fails, authenticate the failing tool to the intended tenant through its
normal broker or browser flow, then retry the failed operation.

For the outstanding [MFA/token-expiry report](https://github.com/nathanmcnulty/azd-maester/issues/15),
capture the failing command and stage, tool versions, selected subscription
and tenant, and redacted error code/message. Do not include access tokens,
credential-cache files, or unredacted authentication logs. The post-provision
context regression tests provide offline boundary evidence; they do not
prove the reported MFA failure is resolved.

Microsoft Graph delegated setup uses the separately configured tenant-owned public client and canonical exact-tenant/client/account/scope coordinator. Azure CLI Graph tokens and shared SDK clients are not substitutes. See [setup consent](setup-consent.md) for the complete selected union and staged runtime bootstrap.
