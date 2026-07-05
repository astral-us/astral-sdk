import Foundation

/// AWS/Cognito endpoints for the reference cloud backend (Cognito auth, IoT Core MQTT
/// telemetry, and an API Gateway that forwards dialog escalation to an LLM). Loaded from a
/// plist you provide rather than baked into source — see `PhroverCloud.example.plist` for
/// the expected keys. Bring your own values if you're pointing at your own backend instead
/// of the reference `eco/aws` stack.
public struct PhroverCloudConfig: Sendable {
    public let region: String
    public let apiEndpoint: String
    public let identityPoolId: String
    public let userPoolId: String
    public let iotEndpoint: String
    public let cognitoClientId: String

    public init(region: String,
                apiEndpoint: String,
                identityPoolId: String,
                userPoolId: String,
                iotEndpoint: String,
                cognitoClientId: String) {
        self.region = region
        self.apiEndpoint = apiEndpoint
        self.identityPoolId = identityPoolId
        self.userPoolId = userPoolId
        self.iotEndpoint = iotEndpoint
        self.cognitoClientId = cognitoClientId
    }

    /// Load from a plist with string keys: Region, APIEndpoint, IdentityPoolId, UserPoolId,
    /// IoTEndpoint, CognitoClientId.
    public init?(contentsOfPlist url: URL) {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
              let region = plist["Region"],
              let apiEndpoint = plist["APIEndpoint"],
              let identityPoolId = plist["IdentityPoolId"],
              let userPoolId = plist["UserPoolId"],
              let iotEndpoint = plist["IoTEndpoint"],
              let cognitoClientId = plist["CognitoClientId"] else {
            return nil
        }
        self.init(region: region, apiEndpoint: apiEndpoint, identityPoolId: identityPoolId,
                  userPoolId: userPoolId, iotEndpoint: iotEndpoint, cognitoClientId: cognitoClientId)
    }
}
