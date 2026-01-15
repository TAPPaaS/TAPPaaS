<?php

/**
 * @filename    AssignSettingsController.php
 * @package     OPNsense\Interfaces\Api
 * @author      Maciej Szymczak <maciej@szymczak.at>
 * @copyright   (c) 2025 Maciej Szymczak
 * @license     BSD-2-Clause
 *
 * Description: OPNsense API endpoint for assigning, configuring, and deleting
 *              logical interfaces (OPTx). Handles creation with static/DHCP/none
 *              IPv4 configuration, MAC spoofing, and deletion.
 *
 *  Required Path: /usr/local/opnsense/mvc/app/controllers/OPNsense/Interfaces/Api/AssignSettingsController.php
 *
 */

namespace OPNsense\Interfaces\Api;

use OPNsense\Base\ApiControllerBase;
use OPNsense\Base\UserException;
use OPNsense\Core\Backend;
use OPNsense\Core\Config;

class AssignSettingsController extends ApiControllerBase
{
    // --- Constants for Configuration Keys and Values ---
    private const CONFIG_KEY_INTERFACES = 'interfaces';
    private const CONFIG_KEY_IF = 'if';
    private const CONFIG_KEY_DESCR = 'descr';
    private const CONFIG_KEY_ENABLE = 'enable';
    private const CONFIG_KEY_SPOOFMAC = 'spoofmac';
    private const CONFIG_KEY_IPADDR = 'ipaddr';
    private const CONFIG_KEY_SUBNET = 'subnet';
    private const CONFIG_KEY_DHCP = 'dhcp';

    private const IPV4_TYPE_STATIC = 'static';
    private const IPV4_TYPE_DHCP = 'dhcp';
    private const IPV4_TYPE_NONE = 'none';

    private const BACKEND_INTERFACE_RECONFIGURE = 'interface reconfigure all';

    /**
     * Add and configure a new OPT interface.
     *
     * Creates a new OPT interface (optX), assigns the specified kernel device,
     * description, and optionally configures enable status, MAC spoofing,
     * and static IPv4 settings.
     *
     * **Validation:** Checks if the specified 'device' is already assigned to
     * another interface before proceeding.
     *
     * Expected JSON payload structure within 'assign' object:
     * {
     *   "assign": {
     *     "device": "vlan0.XXX",         // Required: Kernel device name
     *     "description": "My Interface", // Required: Interface description
     *     "enable": true,                // Optional: boolean, defaults to false (disabled)
     *     "spoofMac": "00:11:...",       // Optional: string, MAC address format
     *     "ipv4Type": "static",          // Optional: "static", "dhcp", "none". Determines IP config. Defaults to "none".
     *     "ipv4Address": "10.1.2.3",     // Required if ipv4Type is "static"
     *     "ipv4Subnet": 24               // Required if ipv4Type is "static" (integer 1-32)
     *   }
     * }
     *
     * NOTE: Triggers an 'interface reconfigure all' command upon successful save.
     *
     * @return array Status result including the assigned interface name ('ifname', e.g., 'opt1').
     * @throws UserException on invalid input, device already assigned, or configuration errors.
     */
    public function AddItemAction()
    {
        $result = ["result" => "failed"];
        $ifname = null;
        $log_prefix = "[AssignSettingsController::AddItemAction]";
        error_log("{$log_prefix} --- Request Received ---");
        $this->sessionClose();

        try {
            error_log("{$log_prefix} Getting JSON payload...");
            $request_body = $this->request->getJsonRawBody(true);
            $data = $request_body['assign'] ?? null;
            error_log("{$log_prefix} Payload data: " . print_r($data, true)); // Keep for debug, consider removing/conditionalizing later

            // --- Basic Payload Validation ---
            if (empty($data) || !is_array($data)) {
                throw new UserException("Invalid payload structure. Expected 'assign' object.");
            }
            if (empty($data['device']) || !is_string($data['device'])) {
                throw new UserException("Payload missing required 'device' field (string).");
            }
            if (empty($data['description']) || !is_string($data['description'])) {
                throw new UserException("Payload missing required 'description' field (string).");
            }

            $kernel_device = trim($data['device']); // Device to be assigned
            $description = trim($data['description']);
            if (!preg_match('/^[a-zA-Z0-9_.\-]+$/', $kernel_device)) {
                throw new UserException("Invalid format for 'device' field '{$kernel_device}'.");
            }

            // Optional fields parsing and validation...
            $enable = filter_var($data['enable'] ?? false, FILTER_VALIDATE_BOOLEAN);
            $spoofMac = isset($data['spoofMac']) ? trim($data['spoofMac']) : null;
            $ipv4ConfigurationType = isset($data['ipv4Type']) ? trim(strtolower($data['ipv4Type'])) : self::IPV4_TYPE_NONE;
            $ipv4Address = isset($data['ipv4Address']) ? trim($data['ipv4Address']) : null;
            $ipv4Subnet = isset($data['ipv4Subnet']) ? $data['ipv4Subnet'] : null;

            // Validation logic for optional fields
            if ($spoofMac !== null) {
                if ($spoofMac === '' || !filter_var($spoofMac, FILTER_VALIDATE_MAC)) {
                    throw new UserException("Invalid format for 'spoofMac' field. Expected standard MAC address format.");
                }
            }
            $allowedIpv4Types = [self::IPV4_TYPE_STATIC, self::IPV4_TYPE_DHCP, self::IPV4_TYPE_NONE];
            if (!in_array($ipv4ConfigurationType, $allowedIpv4Types)) {
                throw new UserException("Invalid 'ipv4Type' specified. Allowed values: " . implode(', ', $allowedIpv4Types));
            }
            if ($ipv4ConfigurationType === self::IPV4_TYPE_STATIC) {
                if (empty($ipv4Address) || filter_var($ipv4Address, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4) === false) {
                    throw new UserException("Invalid or missing 'ipv4Address' for ipv4Type '" . self::IPV4_TYPE_STATIC . "'.");
                }
                if ($ipv4Subnet === null || !filter_var($ipv4Subnet, FILTER_VALIDATE_INT, ['options' => ['min_range' => 1, 'max_range' => 32]])) {
                    throw new UserException("Invalid or missing 'ipv4Subnet' for ipv4Type '" . self::IPV4_TYPE_STATIC . "'. Expected integer between 1 and 32.");
                }
            } else {
                if (!empty($ipv4Address) || $ipv4Subnet !== null) {
                    throw new UserException("'ipv4Address' and 'ipv4Subnet' should only be provided when 'ipv4Type' is '" . self::IPV4_TYPE_STATIC . "'.");
                }
            }
            error_log("{$log_prefix} Payload validation complete.");


            // --- Load Config and Check for Existing Device Assignment ---
            error_log("{$log_prefix} Loading config...");
            $config = Config::getInstance();
            $configHandle = $config->object();
            error_log("{$log_prefix} Config loaded.");

            error_log("{$log_prefix} Checking if device '{$kernel_device}' is already assigned...");
            if (isset($configHandle->{self::CONFIG_KEY_INTERFACES})) {
                foreach ($configHandle->{self::CONFIG_KEY_INTERFACES}->children() as $existing_ifname => $node) {
                    // Check if the node has an <if> tag and if its value matches the requested device
                    if (isset($node->{self::CONFIG_KEY_IF}) && (string)$node->{self::CONFIG_KEY_IF} === $kernel_device) {
                        $error_message = "Device '{$kernel_device}' is already assigned to interface '{$existing_ifname}'. Cannot assign it again.";
                        error_log("{$log_prefix} {$error_message}");
                        throw new UserException($error_message);
                    }
                }
            }
            error_log("{$log_prefix} Device '{$kernel_device}' is not currently assigned. Proceeding.");


            // --- Determine Next Available Interface Name ---
            error_log("{$log_prefix} Determining next available OPT interface name...");
            $max_opt_num = 0;
            if (isset($configHandle->{self::CONFIG_KEY_INTERFACES})) {
                foreach ($configHandle->{self::CONFIG_KEY_INTERFACES}->children() as $current_ifname => $node) {
                    if (preg_match('/^opt(\d+)$/', (string)$current_ifname, $matches)) {
                        $num = intval($matches[1]);
                        if ($num > $max_opt_num) {
                            $max_opt_num = $num;
                        }
                    }
                }
            }
            $ifname = "opt" . ($max_opt_num + 1);
            error_log("{$log_prefix} Determined next available interface name: " . $ifname);

            if (isset($configHandle->{self::CONFIG_KEY_INTERFACES}->{$ifname})) {
                // This check should ideally never fail if the max_opt_num logic is correct, but keep as safety net
                throw new \Exception("Calculated interface name '{$ifname}' unexpectedly already exists in config.");
            }

            // --- Apply Configuration ---
            error_log("{$log_prefix} Applying configuration to node '{$ifname}'...");
            $newNode = $configHandle->{self::CONFIG_KEY_INTERFACES}->addChild($ifname);

            $newNode->{self::CONFIG_KEY_IF} = $kernel_device;
            $newNode->{self::CONFIG_KEY_DESCR} = $description;
            error_log("{$log_prefix} Set {$ifname}->" . self::CONFIG_KEY_IF . " = " . $kernel_device);
            error_log("{$log_prefix} Set {$ifname}->" . self::CONFIG_KEY_DESCR . " = " . $description);

            if ($enable) {
                $newNode->addChild(self::CONFIG_KEY_ENABLE, '1');
                error_log("{$log_prefix} Set {$ifname}->" . self::CONFIG_KEY_ENABLE . " = 1");
            }
            if ($spoofMac !== null) {
                $newNode->{self::CONFIG_KEY_SPOOFMAC} = $spoofMac;
                error_log("{$log_prefix} Set {$ifname}->" . self::CONFIG_KEY_SPOOFMAC . " = " . $spoofMac);
            }

            switch ($ipv4ConfigurationType) {
                case self::IPV4_TYPE_STATIC:
                    $newNode->{self::CONFIG_KEY_IPADDR} = $ipv4Address;
                    $newNode->{self::CONFIG_KEY_SUBNET} = $ipv4Subnet;
                    error_log("{$log_prefix} Set {$ifname}->" . self::CONFIG_KEY_IPADDR . " = " . $ipv4Address);
                    error_log("{$log_prefix} Set {$ifname}->" . self::CONFIG_KEY_SUBNET . " = " . $ipv4Subnet);
                    if (isset($newNode->{self::CONFIG_KEY_DHCP})) {
                        unset($newNode->{self::CONFIG_KEY_DHCP});
                    }
                    break;
                case self::IPV4_TYPE_DHCP:
                    $newNode->{self::CONFIG_KEY_IPADDR} = self::IPV4_TYPE_DHCP;
                    if (isset($newNode->{self::CONFIG_KEY_SUBNET})) {
                        unset($newNode->{self::CONFIG_KEY_SUBNET});
                    }
                    $newNode->addChild(self::CONFIG_KEY_DHCP, ''); // Add empty <dhcp/> tag
                    error_log("{$log_prefix} Set {$ifname}->" . self::CONFIG_KEY_IPADDR . " = " . self::IPV4_TYPE_DHCP);
                    break;
                case self::IPV4_TYPE_NONE:
                default:
                    // Ensure previous settings are cleared if switching to 'none'
                    if (isset($newNode->{self::CONFIG_KEY_IPADDR})) {
                        unset($newNode->{self::CONFIG_KEY_IPADDR});
                    }
                    if (isset($newNode->{self::CONFIG_KEY_SUBNET})) {
                        unset($newNode->{self::CONFIG_KEY_SUBNET});
                    }
                    if (isset($newNode->{self::CONFIG_KEY_DHCP})) {
                        unset($newNode->{self::CONFIG_KEY_DHCP});
                    }
                    error_log("{$log_prefix} No IPv4 configuration specified for {$ifname}.");
                    break;
            }

            // --- Save and Apply ---
            error_log("{$log_prefix} Saving configuration changes for '{$ifname}'...");
            $config->save();
            error_log("{$log_prefix} Configuration saved for '{$ifname}'.");

            // Trigger backend reconfigure
            error_log("{$log_prefix} Running backend command '" . self::BACKEND_INTERFACE_RECONFIGURE . "'...");
            $backend = new Backend();
            $backend_result = $backend->configdRun(self::BACKEND_INTERFACE_RECONFIGURE);
            error_log("{$log_prefix} Backend command '" . self::BACKEND_INTERFACE_RECONFIGURE . "' finished. Result: " . trim($backend_result));

            $result['result'] = 'saved';
            $result['ifname'] = $ifname;
            error_log("{$log_prefix} Interface '{$ifname}' created and configured successfully. Returning: " . json_encode($result));

        } catch (UserException $e) { // Catch the UserException from our check or validation
            error_log("{$log_prefix} UserException: " . $e->getMessage());
            $this->response->setStatusCode(400, "Bad Request");
            $result = ["result" => "failed", "errorMessage" => $e->getMessage()];
            error_log("{$log_prefix} Returning UserException Response: " . json_encode($result));

        } catch (\Exception $e) {
            $error_details = $e->getMessage() . " (File: " . $e->getFile() . ", Line: " . $e->getLine() . ")";
            error_log("{$log_prefix} CRITICAL EXCEPTION during AddItemAction: " . $error_details);
            error_log("{$log_prefix} Trace: " . $e->getTraceAsString());
            $this->response->setStatusCode(500, "Internal Server Error");
            $result = ["result" => "failed", "errorMessage" => "An unexpected server error occurred. Please check logs."];
            error_log("{$log_prefix} Returning General Exception Response: " . json_encode($result));
        }

        error_log("{$log_prefix} --- Request Finished ---");
        return $result;
    }

    /**
     * Deletes the configuration node for a specified logical interface.
     * This completely removes the interface definition (e.g., <opt1>...</opt1>)
     * from the configuration. Triggers an interface reconfigure command after saving.
     *
     * @param string $uuid The logical interface name (e.g., 'opt1') to delete.
     * @return array ['result' => 'deleted'] on success or error details.
     * @throws UserException on missing or invalid uuid parameter or attempt to delete core interface.
     */
    public function delItemAction($uuid)
    {
        $result = ["result" => "failed"]; // Default to failure
        $log_prefix = "[AssignSettingsController::delItemAction]";

        error_log("{$log_prefix} --- Request Received to DELETE interface '{$uuid}' ---");
        $this->sessionClose();

        try {
            // Validate the input UUID (logical interface name)
            if (empty($uuid)) {
                throw new UserException(gettext("Required parameter 'uuid' (logical interface name) is missing."));
            }
            // Basic validation for typical OPNsense interface names
            if (!preg_match('/^[a-zA-Z0-9_]+$/', $uuid)) {
                throw new UserException(gettext("Invalid format for parameter 'uuid'."));
            }
            // Prevent accidental deletion of core interfaces (example)
            if (in_array(strtolower($uuid), ['lan', 'wan'])) {
                throw new UserException(gettext("Deletion of core interfaces like 'lan' or 'wan' is not permitted via this action."));
            }

            error_log("{$log_prefix} Loading configuration to delete '{$uuid}'...");
            $config = Config::getInstance();
            $configHandle = $config->object();
            error_log("{$log_prefix} Configuration loaded.");

            // Check if the specified interface configuration node exists
            if (!isset($configHandle->{self::CONFIG_KEY_INTERFACES}->{$uuid})) {
                error_log("{$log_prefix} Interface '{$uuid}' not found in configuration. Assuming already deleted (idempotent success).");
                // Return 'deleted' as the state is already the desired outcome.
                return ["result" => "deleted", "message" => "Interface '{$uuid}' not found, assumed already deleted."];
            }
            error_log("{$log_prefix} Interface '{$uuid}' found. Proceeding with deletion.");

            // --- Delete the interface node ---
            // Unsetting the property on the SimpleXMLElement effectively removes the node
            unset($configHandle->{self::CONFIG_KEY_INTERFACES}->{$uuid});
            error_log("{$log_prefix} Removed interface node '{$uuid}' from configuration object.");

            // --- Save and Apply ---
            error_log("{$log_prefix} Saving configuration after deleting '{$uuid}'...");
            $config->save();
            error_log("{$log_prefix} Configuration saved successfully.");

            // Trigger a backend command to apply the configuration changes system-wide
            error_log("{$log_prefix} Running backend command '" . self::BACKEND_INTERFACE_RECONFIGURE . "'...");
            $backend = new Backend();
            $backend_result = $backend->configdRun(self::BACKEND_INTERFACE_RECONFIGURE);
            error_log("{$log_prefix} Backend command '" . self::BACKEND_INTERFACE_RECONFIGURE . "' finished. Result: " . trim($backend_result));

            // Report success: the interface node was actually deleted.
            $result = ["result" => "deleted"];
            error_log("{$log_prefix} Successfully deleted interface configuration for '{$uuid}'.");

        } catch (UserException $e) {
            error_log("{$log_prefix} UserException: " . $e->getMessage());
            $this->response->setStatusCode(400, "Bad Request");
            $result = ["result" => "failed", "errorMessage" => $e->getMessage()];
            error_log("{$log_prefix} Returning UserException Response: " . json_encode($result));

        } catch (\Exception $e) {
            $error_details = $e->getMessage() . " (File: " . $e->getFile() . ", Line: " . $e->getLine() . ")";
            error_log("{$log_prefix} CRITICAL EXCEPTION during deletion of '{$uuid}': " . $error_details);
            error_log("{$log_prefix} Trace: " . $e->getTraceAsString());
            $this->response->setStatusCode(500, "Internal Server Error");
            // Generic error message to avoid leaking details
            $result = ["result" => "failed", "errorMessage" => "An unexpected server error occurred during deletion. Please check logs."];
            error_log("{$log_prefix} Returning General Exception Response: " . json_encode($result));
        }

        error_log("{$log_prefix} --- Request Finished for '{$uuid}' ---");
        return $result; // Return final result (success or caught exception)
    }
}