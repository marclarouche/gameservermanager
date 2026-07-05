<#
.SYNOPSIS
    Least-privilege local service account provisioning for GSM.
.DESCRIPTION
    Phase 1. Creates and configures a dedicated local Windows account under
    which game servers run, instead of the interactive admin account. Grants
    only what's needed: write access to GSM's install/config/log/backup
    folders and permission to bind the server's ports. Does not grant local
    admin rights.

    This module only provisions the account. Using that account to actually
    run a server as a Windows service is Core/Service.psm1 (Phase 2).
.NOTES
    Functions to implement:
    - New-GSMServiceAccount        Creates the local account if it doesn't exist
    - Set-GSMServiceAccountRights  Grants folder ACLs and port binding rights
    - Test-GSMServiceAccount       Verifies the account exists and has the
                                    expected (and only the expected) rights
    - Remove-GSMServiceAccount     Removes the account during uninstall
#>

Set-StrictMode -Version Latest
