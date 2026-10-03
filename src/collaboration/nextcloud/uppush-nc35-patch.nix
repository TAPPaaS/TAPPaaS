# uppush 2.6.0 on Nextcloud 35 (upstream uppush #124, open): 35's ISchemaWrapper
# returns OCP\DB\Schema\ITable, not Doctrine's Table, so the first migration dies
# with a TypeError. Same fix as nextcloud/mail#13459. A .nix file, not a .patch,
# because update-os.sh ships only the module's *.nix siblings to /etc/nixos.
{ writeText }:
writeText "uppush-nc35-schema-table.patch" ''
--- a/lib/Migration/Version020205.php
+++ b/lib/Migration/Version020205.php
@@ -8,6 +8,7 @@
 use Exception;
 use DateTimeImmutable;
 use Doctrine\DBAL\Schema\Table;
+use OCP\DB\Schema\ITable;
 use Doctrine\DBAL\Types\Types;
 use Doctrine\DBAL\Types\DateTimeImmutableType;
 use OCA\UnifiedPushProvider\Utils;
@@ -201,7 +202,7 @@
 		}
 	}
 
-	function createDevicesTable(ISchemaWrapper $schema, string $suffix = '''): Table {
+	function createDevicesTable(ISchemaWrapper $schema, string $suffix = '''): Table|ITable {
 		$devicesTable = $schema->createTable('uppush_devices' . $suffix);
 		$devicesTable->addColumn('user_id', Types::STRING, [
 			'notnull' => true,
@@ -221,7 +222,7 @@
 		return $devicesTable;
 	}
 
-	function createApplicationsTable(ISchemaWrapper $schema, Table $devicesTable, string $suffix = '''): void {
+	function createApplicationsTable(ISchemaWrapper $schema, Table|ITable $devicesTable, string $suffix = '''): void {
 		$appTable = $schema->createTable('uppush_applications' . $suffix);
 		$appTable->addColumn('device_id', Types::STRING, [
 			'notnull' => true,
@@ -258,7 +259,7 @@
 		}
 		$this->log("New apps table, using FK: " . $fk);
 		$appTable->addForeignKeyConstraint(
-			$devicesTable,
+			$devicesTable->getName(),
 			['device_id'],
 			['device_id'],
 			["onDelete" => "CASCADE"],
''
