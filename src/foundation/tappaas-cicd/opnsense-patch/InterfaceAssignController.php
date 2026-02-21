<?php

/**
 * @filename    InterfaceAssignController.php
 * @package     OPNsense\Interfaces\Api
 * @author      TAPPaaS Team
 * @copyright   (c) 2026
 * @license     BSD-2-Clause
 *
 * Description: OPNsense API endpoint for assigning and configuring
 *              logical interfaces (OPTx). Handles creation with static IPv4
 *              configuration and deletion.
 *
 * Required Path: /usr/local/opnsense/mvc/app/controllers/OPNsense/Interfaces/Api/InterfaceAssignController.php
 *
 * Compatible with: OPNsense 26.1+
 */

namespace OPNsense\Interfaces\Api;

use OPNsense\Base\ApiControllerBase;
use OPNsense\Base\UserException;
use OPNsense\Core\Backend;
use OPNsense\Core\Config;

class InterfaceAssignController extends ApiControllerBase
{
    // --- Constants for Configuration Keys and Values ---
    private const CONFIG_KEY_INTERFACES = 'interfaces';
    private const CONFIG_KEY_IF = 'if';
    private const CONFIG_KEY_DESCR = 'descr';
    private const CONFIG_KEY_ENABLE = 'enable';
    private const CONFIG_KEY_IPADDR = 'ipaddr';
    private const CONFIG_KEY_SUBNET = 'subnet';
    private const IPV4_TYPE_STATIC = 'static';
    private const BACKEND_INTERFACE_RECONFIGURE = 'interface reconfigure all';

    /**
     * Add and configure a new OPT interface.
     *
     * Creates a new OPT interface (optX), assigns the specified kernel device,
     * description, and configures with static IPv4 settings.
     *
     * Expected JSON payload structure within 'assign' object:
     * {
     *   "assign": {
     *     "device": "vlan0.XXX",         // Required: Kernel device name
     *     "description": "My Interface", // Required: Interface description
     *     "enable": true,                // Optional: boolean, defaults to false
     *     "ipv4Address": "10.1.2.3",     // Required: IPv4 address
     *     "ipv4Subnet": 24               // Required: Subnet mask (1-32)
     *   }
     * }
     *
     * NOTE: Triggers an 'interface reconfigure all' command upon successful save.
     *
     * @return array Status result including the assigned interface name ('ifname', e.g., 'opt1').
     * @throws UserException on invalid input, device already assigned, or configuration errors.
     */
    public function addItemAction()
    {
        $result = ["result" => "failed"];
        $ifname = null;
        $log_prefix = "[InterfaceAssignController::addItemAction]";
        syslog(LOG_INFO, "{$log_prefix} --- Request Received ---");
        // NOTE: sessionClose() causes issues in OPNsense 26.1 with ApiControllerBase - removed

        try {
            syslog(LOG_INFO, "{$log_prefix} Getting JSON payload...");
            $request_body = $this->request->getJsonRawBody(true);
            $data = $request_body['assign'] ?? null;

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

            $kernel_device = trim($data['device']);
            $description = trim($data['description']);
            if (!preg_match('/^[a-zA-Z0-9_.\-]+$/', $kernel_device)) {
                throw new UserException("Invalid format for 'device' field '{$kernel_device}'.");
            }

            $enable = filter_var($data['enable'] ?? false, FILTER_VALIDATE_BOOLEAN);
            $ipv4Address = isset($data['ipv4Address']) ? trim($data['ipv4Address']) : null;
            $ipv4Subnet = isset($data['ipv4Subnet']) ? $data['ipv4Subnet'] : null;

            // Validate IPv4 settings
            if (empty($ipv4Address) || filter_var($ipv4Address, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4) === false) {
                throw new UserException("Invalid or missing 'ipv4Address'.");
            }
            if ($ipv4Subnet === null || !filter_var($ipv4Subnet, FILTER_VALIDATE_INT, ['options' => ['min_range' => 1, 'max_range' => 32]])) {
                throw new UserException("Invalid or missing 'ipv4Subnet'. Expected integer between 1 and 32.");
            }

            syslog(LOG_INFO, "{$log_prefix} Payload validation complete.");

            // --- Load Config and Check for Existing Device Assignment ---
            syslog(LOG_INFO, "{$log_prefix} Loading config...");
            $config = Config::getInstance();
            $configHandle = $config->object();
            syslog(LOG_INFO, "{$log_prefix} Config loaded.");

            syslog(LOG_INFO, "{$log_prefix} Checking if device '{$kernel_device}' is already assigned...");
            if (isset($configHandle->{self::CONFIG_KEY_INTERFACES})) {
                foreach ($configHandle->{self::CONFIG_KEY_INTERFACES}->children() as $existing_ifname => $node) {
                    if (isset($node->{self::CONFIG_KEY_IF}) && (string)$node->{self::CONFIG_KEY_IF} === $kernel_device) {
                        $error_message = "Device '{$kernel_device}' is already assigned to interface '{$existing_ifname}'. Cannot assign it again.";
                        syslog(LOG_ERR, "{$log_prefix} {$error_message}");
                        throw new UserException($error_message);
                    }
                }
            }
            syslog(LOG_INFO, "{$log_prefix} Device '{$kernel_device}' is not currently assigned. Proceeding.");

            // --- Determine Next Available Interface Name ---
            syslog(LOG_INFO, "{$log_prefix} Determining next available OPT interface name...");
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
            syslog(LOG_INFO, "{$log_prefix} Determined next available interface name: " . $ifname);

            if (isset($configHandle->{self::CONFIG_KEY_INTERFACES}->{$ifname})) {
                throw new \Exception("Calculated interface name '{$ifname}' unexpectedly already exists in config.");
            }

            // --- Apply Configuration ---
            syslog(LOG_INFO, "{$log_prefix} Applying configuration to node '{$ifname}'...");
            $newNode = $configHandle->{self::CONFIG_KEY_INTERFACES}->addChild($ifname);

            $newNode->{self::CONFIG_KEY_IF} = $kernel_device;
            $newNode->{self::CONFIG_KEY_DESCR} = $description;
            syslog(LOG_INFO, "{$log_prefix} Set {$ifname}->" . self::CONFIG_KEY_IF . " = " . $kernel_device);
            syslog(LOG_INFO, "{$log_prefix} Set {$ifname}->" . self::CONFIG_KEY_DESCR . " = " . $description);

            if ($enable) {
                $newNode->addChild(self::CONFIG_KEY_ENABLE, '1');
                syslog(LOG_INFO, "{$log_prefix} Set {$ifname}->" . self::CONFIG_KEY_ENABLE . " = 1");
            }

            $newNode->{self::CONFIG_KEY_IPADDR} = $ipv4Address;
            $newNode->{self::CONFIG_KEY_SUBNET} = $ipv4Subnet;
            syslog(LOG_INFO, "{$log_prefix} Set {$ifname}->" . self::CONFIG_KEY_IPADDR . " = " . $ipv4Address);
            syslog(LOG_INFO, "{$log_prefix} Set {$ifname}->" . self::CONFIG_KEY_SUBNET . " = " . $ipv4Subnet);

            // --- Save and Apply ---
            syslog(LOG_INFO, "{$log_prefix} Saving configuration changes for '{$ifname}'...");
            $config->save();
            syslog(LOG_INFO, "{$log_prefix} Configuration saved for '{$ifname}'.");

            // Trigger backend reconfigure
            syslog(LOG_INFO, "{$log_prefix} Running backend command '" . self::BACKEND_INTERFACE_RECONFIGURE . "'...");
            $backend = new Backend();
            $backend_result = $backend->configdRun(self::BACKEND_INTERFACE_RECONFIGURE);
            syslog(LOG_INFO, "{$log_prefix} Backend command '" . self::BACKEND_INTERFACE_RECONFIGURE . "' finished. Result: " . trim($backend_result));

            $result['result'] = 'saved';
            $result['ifname'] = $ifname;
            syslog(LOG_INFO, "{$log_prefix} Interface '{$ifname}' created and configured successfully. Returning: " . json_encode($result));

        } catch (UserException $e) {
            syslog(LOG_ERR, "{$log_prefix} UserException: " . $e->getMessage());
            $this->response->setStatusCode(400, "Bad Request");
            $result = ["result" => "failed", "errorMessage" => $e->getMessage()];
            syslog(LOG_INFO, "{$log_prefix} Returning UserException Response: " . json_encode($result));

        } catch (\Exception $e) {
            $error_details = $e->getMessage() . " (File: " . $e->getFile() . ", Line: " . $e->getLine() . ")";
            syslog(LOG_ERR, "{$log_prefix} CRITICAL EXCEPTION during addItemAction: " . $error_details);
            syslog(LOG_ERR, "{$log_prefix} Trace: " . $e->getTraceAsString());
            $this->response->setStatusCode(500, "Internal Server Error");
            $result = ["result" => "failed", "errorMessage" => "An unexpected server error occurred: " . $e->getMessage()];
            syslog(LOG_INFO, "{$log_prefix} Returning General Exception Response: " . json_encode($result));
        }

        syslog(LOG_INFO, "{$log_prefix} --- Request Finished ---");
        return $result;
    }

    /**
     * Deletes the configuration node for a specified logical interface.
     *
     * @param string $uuid The logical interface name (e.g., 'opt1') to delete.
     * @return array ['result' => 'deleted'] on success or error details.
     * @throws UserException on missing or invalid uuid parameter or attempt to delete core interface.
     */
    public function delItemAction($uuid)
    {
        $result = ["result" => "failed"];
        $log_prefix = "[InterfaceAssignController::delItemAction]";

        syslog(LOG_INFO, "{$log_prefix} --- Request Received to DELETE interface '{$uuid}' ---");
        // NOTE: sessionClose() causes issues in OPNsense 26.1 with ApiControllerBase - removed

        try {
            if (empty($uuid)) {
                throw new UserException("Required parameter 'uuid' (logical interface name) is missing.");
            }

            if (!preg_match('/^[a-zA-Z0-9_]+$/', $uuid)) {
                throw new UserException("Invalid format for parameter 'uuid'.");
            }

            if (in_array(strtolower($uuid), ['lan', 'wan'])) {
                throw new UserException("Deletion of core interfaces like 'lan' or 'wan' is not permitted.");
            }

            syslog(LOG_INFO, "{$log_prefix} Loading configuration to delete '{$uuid}'...");
            $config = Config::getInstance();
            $configHandle = $config->object();
            syslog(LOG_INFO, "{$log_prefix} Configuration loaded.");

            if (!isset($configHandle->{self::CONFIG_KEY_INTERFACES}->{$uuid})) {
                syslog(LOG_INFO, "{$log_prefix} Interface '{$uuid}' not found in configuration. Assuming already deleted (idempotent success).");
                $result['result'] = 'deleted';
                return $result;
            }

            syslog(LOG_INFO, "{$log_prefix} Deleting interface '{$uuid}' from configuration...");
            unset($configHandle->{self::CONFIG_KEY_INTERFACES}->{$uuid});
            $config->save();
            syslog(LOG_INFO, "{$log_prefix} Configuration saved after deleting '{$uuid}'.");

            $backend = new Backend();
            $backend_result = $backend->configdRun(self::BACKEND_INTERFACE_RECONFIGURE);
            syslog(LOG_INFO, "{$log_prefix} Backend command '" . self::BACKEND_INTERFACE_RECONFIGURE . "' finished. Result: " . trim($backend_result));

            $result['result'] = 'deleted';
            syslog(LOG_INFO, "{$log_prefix} Interface '{$uuid}' deleted successfully.");

        } catch (UserException $e) {
            syslog(LOG_ERR, "{$log_prefix} UserException: " . $e->getMessage());
            $this->response->setStatusCode(400, "Bad Request");
            $result = ["result" => "failed", "errorMessage" => $e->getMessage()];
        } catch (\Exception $e) {
            $error_details = $e->getMessage() . " (File: " . $e->getFile() . ", Line: " . $e->getLine() . ")";
            syslog(LOG_ERR, "{$log_prefix} CRITICAL EXCEPTION: " . $error_details);
            $this->response->setStatusCode(500, "Internal Server Error");
            $result = ["result" => "failed", "errorMessage" => "An unexpected server error occurred: " . $e->getMessage()];
        }

        syslog(LOG_INFO, "{$log_prefix} --- Request Finished ---");
        return $result;
    }
}
