# Nier OneDrive integration

The setup wizard detects the signed-in Microsoft email after authorization and
saves it in the account's private `account.json`. The widget reads this metadata
without accessing credentials or making identity requests on each poll. An
optional typed email remains a fallback if Microsoft cannot return an address.

Existing accounts can refresh their identity from the wizard's account menu or:

```sh
nier-onedrive-setup --refresh-identity ACCOUNT_ID
```

Identity detection uses the client's public application ID, tenant and national
cloud configuration. It obtains a temporary access token using the existing
sign-in and queries the signed-in user's default drive owner in Microsoft Graph;
if the owner omits an email, it tries the profile using existing permissions.
It never requests extra scopes, logs tokens, rewrites client credentials, starts
synchronization, or restarts an account service. Failed lookups preserve saved
identity metadata. The client continues to own refresh-token persistence.
