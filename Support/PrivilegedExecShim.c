#include <Security/Authorization.h>

OSStatus PulseAuthorizationExecuteWithPrivileges(
    AuthorizationRef authorization,
    const char *pathToTool,
    char *const *arguments
) {
    return AuthorizationExecuteWithPrivileges(
        authorization,
        pathToTool,
        kAuthorizationFlagDefaults,
        arguments,
        NULL
    );
}
