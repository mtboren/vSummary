<?php
 
/*
 * DataTables example server-side processing script.
 *
 * Please note that this script is intentionally extremely simply to show how
 * server-side processing can be implemented, and probably shouldn't be used as
 * the basis for a large complex system. It is suitable for simple use cases as
 * for learning.
 *
 * See http://datatables.net/usage/server-side for full details on the server-
 * side processing requirements of DataTables.
 *
 * @license MIT - http://datatables.net/license_mit
 */
 

// DB table to use
$table = 'view_vnic';
 
// Table's primary key
$primaryKey = 'id';
 
// Array of database columns which should be read and sent back to DataTables.
// The `db` parameter represents the column name in the database, while the `dt`
// parameter represents the DataTables column identifier. In this case simple
// indexes
$columns = array(
    array( 'db' => 'vm_name', 'dt' => 0 ),
    array( 
        'db' => 'name', 
        'dt' => 1,
        'formatter' => function( $d, $row ) {
            return str_replace("Network adapter", "vNIC #", $d);
        }
    ),
    array( 'db' => 'mac', 'dt' => 2 ),
    array( 'db' => 'type', 'dt' => 3 ),
    array( 'db' => 'connected', 'dt' => 4 ),
    array( 'db' => 'status', 'dt' => 5 ),
    array( 'db' => 'esxi_name', 'dt' => 6 ),
    array( 
        'db' => 'portgroup_name', 
        'dt' => 7,
        'formatter' => function( $d, $row ) {
            if ($d === 'ORPHANED'){
                return "NULL";
            }else{
                return $d;
            }
        }
    ),
    array( 
        'db' => 'vlan', 
        'dt' => 8,
        'formatter' => function( $d, $row ) {
            if ($d === '4095'){
                return "ALL";
            }elseif ($d === '0'){
                return "None";
            }else {
                return $d;
            }
        }
    ),
    array( 'db' => 'vswitch_name', 'dt' => 9 ),
    array( 'db' => 'vswitch_type', 'dt' => 10 ),
    array( 'db' => 'vswitch_max_mtu', 'dt' => 11 ),
    array( 'db' => 'vcenter_fqdn', 'dt' => 12 ),
    array( 'db' => 'vcenter_short_name', 'dt' => 13 )

);
 
// Load MYSQL connection details
require_once( 'lib/mysql_config.php' );
  
// Load ssp class
require_once( 'lib/ssp.class.php' );
 
echo json_encode(
    SSP::simple( $_GET, $sql_details, $table, $primaryKey, $columns )
);