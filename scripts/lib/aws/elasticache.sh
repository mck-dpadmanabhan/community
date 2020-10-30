#!/usr/bin/env bash

THIS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
ROOT_DIR="$THIS_DIR/../../.."
SCRIPTS_DIR="$ROOT_DIR/scripts"

. $SCRIPTS_DIR/lib/common.sh
. $SCRIPTS_DIR/lib/testutil.sh
. $SCRIPTS_DIR/lib/aws.sh

service_name="elasticache"

#################################################
# functions for tests
#################################################

# print_k8s_ack_controller_pod_logs prints kubernetes ack controller pod logs
# this function depends upon testutil.sh
print_k8s_ack_controller_pod_logs() {
  local ack_ctrl_pod_id=$( controller_pod_id )
  kubectl logs -n ack-system "$ack_ctrl_pod_id"
}

#################################################
# functions for test data preparation
#################################################

# get_default_vpc puts default and available vpc id to standard output
# get_default_vpc returns status 1 if no default vpc is not found
# Example usage:
#    if ! default_vpc_id="$(get_default_vpc)"; then
#      echo "FATAL: No default vpc id found."
#    else
#      echo "$default_vpc_id"
#    fi
get_default_vpc() {
  local default_vpc_id="$(daws ec2 describe-vpcs --filters Name=isDefault,Values=true Name=state,Values=available --output json | jq -r -e '.Vpcs[0] | .VpcId')"
  if [ -z "$default_vpc_id" ]; then
    echo "FATAL: No default vpc id found."
    return 1
  fi

  echo "$default_vpc_id"
}

# get_default_subnets puts default subnet ids (as json array) from default and available vpc to standard output
# get_default_subnets returns status 1 if no default subnet is not found
# Example usage:
#    if ! aws_subnet_ids_json="$(get_default_subnets)"; then
#      echo "FATAL: No default subnet id found."
#    else
#      # parse json as needed
#      subnets_count="$(echo "$aws_subnet_ids_json" | jq length)"
#      subnet_0="$(echo "$aws_subnet_ids_json" | jq -r -e '.[0]')"
#      for id in $(echo "$aws_subnet_ids_json" | jq -r -e '.[]'); do
#        echo "$id"
#      done
#    fi
get_default_subnets() {
  if ! default_vpc_id="$(get_default_vpc)"; then
    echo "FATAL: No default subnets. No default vpc id found."
    return 1
  fi
  local aws_subnet_ids="$(daws ec2 describe-subnets --filters Name=vpc-id,Values="$default_vpc_id" Name=defaultForAz,Values=true --output json | jq -e '.Subnets[] | .SubnetId')"
  if [ -z "$aws_subnet_ids" ]; then
    return 1
  fi

  local aws_subnet_ids_json="$(echo "$aws_subnet_ids" | jq -s ".")"
  echo "$aws_subnet_ids_json"
}

# get_default_azs puts default availability zones (as json array) from default subnets to standard output
# get_default_azs returns status 1 if no default availability zone is not found
# Example usage:
#    if ! get_default_azs_json="$(get_default_azs)"; then
#      echo "FATAL: No default az found."
#    else
#      # parse json as needed
#      default_az_count="$(echo "$get_default_azs_json" | jq length)"
#      az_0="$(echo "$get_default_azs_json" | jq -r -e '.[0]')"
#      for az in $(echo "$get_default_azs_json" | jq -r -e '.[]'); do
#        echo "$az"
#      done
#    fi
get_default_azs() {
  if ! default_vpc_id="$(get_default_vpc)"; then
    echo "FATAL: No default available zones. No default vpc id found."
    return 1
  fi
  local aws_subnet_default_azs="$(daws ec2 describe-subnets --filters Name=vpc-id,Values="$default_vpc_id" Name=defaultForAz,Values=true --output json | jq -e '.Subnets[] | .AvailabilityZone')"
  if [ -z "$aws_subnet_default_azs" ]; then
    return 1
  fi

  local aws_subnet_default_azs_json="$(echo "$aws_subnet_default_azs" | jq -s ".")"
  echo "$aws_subnet_default_azs_json"
}

#################################################
# functions to test replication group
#################################################

# exit_if_rg_config_application_failed exits if the result of the previous "kubectl apply" command failed
# exit_if_rg_config_application_failed requires 2 arguments:
#   error_code: the error code from the "kubectl apply call"
#   rg_id: the ID of the replication group for failure message in case config application failed
exit_if_rg_config_application_failed() {
  if [[ $# -ne 2 ]]; then
    echo "FATAL: Wrong number of arguments passed to exit_if_rg_config_application_failed"
    echo "Usage: exit_if_rg_config_application_failed error_code rg_id"
    exit 1
  fi

  if [[ $1 -ne 0 ]]; then
    echo "FAIL: application of config for replication group $2 should not have failed"
    exit 1
  fi
}

# clear_rg_parameter_variables unsets the variables used to override default values in provide_replication_group_yaml
# requires no arguments
clear_rg_parameter_variables() {
  unset rg_id
  unset rg_description
  unset automatic_failover_enabled
  unset cache_node_type
  unset num_node_groups
  unset replicas_per_node_group
  unset multi_az_enabled
}


test_default_replication_group="ack-test-rg"
test_default_replication_group_desc="ack-test-rg description"
test_default_replication_group_automatic_failover_enabled="true"
test_default_replication_group_cache_node_type="cache.t3.micro"
test_default_replication_group_num_node_groups="2" # cluster mode enabled
test_default_replication_group_replicas_per_node_group="1"
test_default_replication_group_multi_az_enabled="true"
test_default_replication_group_node_group_id1="0001"
test_default_replication_group_node_group_id2="0002"

# provide_replication_group_yaml puts replication group yaml to standard output
# it uses following environment variables:
#     rg_id, rg_description,
#     automatic_failover_enabled, cache_node_type,
#     num_node_groups, replicas_per_node_group, multi_az_enabled
# if environment variables are not found, then following defaults are used
#     $test_default_replication_group
#     $test_default_replication_group_desc
#     $test_default_replication_group_automatic_failover_enabled
#     $test_default_replication_group_cache_node_type
#     $test_default_replication_group_num_node_groups
#     $test_default_replication_group_replicas_per_node_group
#     $test_default_replication_group_multi_az_enabled
provide_replication_group_yaml() {
  local rg_id="${rg_id:-$test_default_replication_group}"
  local rg_name="$rg_id"
  local rg_description="${rg_description:-$test_default_replication_group_desc}"
  local automatic_failover_enabled="${automatic_failover_enabled:-$test_default_replication_group_automatic_failover_enabled}"
  local cache_node_type="${cache_node_type:=$test_default_replication_group_cache_node_type}"
  local num_node_groups="${num_node_groups:-$test_default_replication_group_num_node_groups}"
  local replicas_per_node_group="${replicas_per_node_group:-$test_default_replication_group_replicas_per_node_group}"
  local multi_az_enabled="${multi_az_enabled:-$test_default_replication_group_multi_az_enabled}"

  cat <<EOF
apiVersion: elasticache.services.k8s.aws/v1alpha1
kind: ReplicationGroup
metadata:
  name: $rg_name
spec:
    engine: redis
    replicationGroupID: $rg_id
    replicationGroupDescription: $rg_description
    automaticFailoverEnabled: $automatic_failover_enabled
    cacheNodeType: $cache_node_type
    numNodeGroups: $num_node_groups
    replicasPerNodeGroup: $replicas_per_node_group
    multiAZEnabled: $multi_az_enabled
EOF
}

# provide_replication_group_yaml_basic is similar to provide_replication_group_yaml, except only specifies
#   a name, description, and engine. This is meant for use cases where certain properties which are usually included
#   need to be excluded from the yaml (e.g. numNodeGroups not specified because replicaCount will be specified).
#   Therefore further properties will need to be appended for this to be a fully specified config.
# provide_replication_group_yaml_basic requires 1 argument:
#   replication_group_id
provide_replication_group_yaml_basic() {
  if [[ $# -ne 1 ]]; then
    echo "FATAL: Wrong number of arguments passed to ${FUNCNAME[0]}"
    echo "${FUNCNAME[0]} replication_group_id"
    exit 1
  fi

  cat <<EOF
apiVersion: elasticache.services.k8s.aws/v1alpha1
kind: ReplicationGroup
metadata:
  name: $1
spec:
    engine: redis
    replicationGroupID: $1
    replicationGroupDescription: default test description
EOF
}

# provide_replication_group_detailed_yaml puts replication group yaml with node groups details to standard output
# it uses following environment variables:
#     rg_id, rg_description, num_node_groups, replicas_per_node_group, node_group_id1, node_group_id2
# if environment variables are not found, then following defaults are used
#     $test_default_replication_group
#     $test_default_replication_group_desc
#     $test_default_replication_group_num_node_groups
#     $test_default_replication_group_replicas_per_node_group
#     $test_default_replication_group_node_group_id1
#     $test_default_replication_group_node_group_id2
provide_replication_group_detailed_yaml() {
  local rg_id="${rg_id:-$test_default_replication_group}"
  local rg_name="$rg_id"
  local rg_description="${rg_description:-$test_default_replication_group_desc}"
  local num_node_groups="${num_node_groups:-$test_default_replication_group_num_node_groups}"
  local replicas_per_node_group="${replicas_per_node_group:-$test_default_replication_group_replicas_per_node_group}"
  local node_group_id1="${node_group_id1:-$test_default_replication_group_node_group_id1}"
  local node_group_id2="${node_group_id2:-$test_default_replication_group_node_group_id2}"
  cat <<EOF
apiVersion: elasticache.services.k8s.aws/v1alpha1
kind: ReplicationGroup
metadata:
  name: $rg_name
spec:
    engine: redis
    replicationGroupID: $rg_id
    replicationGroupDescription: $rg_description
    automaticFailoverEnabled: true
    cacheNodeType: cache.t3.micro
    numNodeGroups: $num_node_groups
    replicasPerNodeGroup: $replicas_per_node_group
    nodeGroupConfiguration:
      - nodeGroupID: "$node_group_id1"
      - nodeGroupID: "$node_group_id2"
EOF
}

# aws_wait_replication_group_available waits for supplied replication_group_id to be in available status
# aws_wait_replication_group_available requires 2 arguments
#     replication_group_id
#     error_message - message to print when wait is over with failure
aws_wait_replication_group_available() {
  if [[ $# -ne 2 ]]; then
    echo "FATAL: Wrong number of arguments passed to aws_wait_replication_group_available"
    echo "Usage: aws_wait_replication_group_available replication_group_id failure_message"
    exit 1
  fi
  local replication_group_id="$1"
  local failure_message="$2"
  local wait_failed="true"
  for i in $(seq 0 5); do
    k8s_controller_reload_credentials "$service_name"
    debug_msg "starting to wait for replication group: $replication_group_id to be available."
    $(daws elasticache wait replication-group-available --replication-group-id "$replication_group_id")
    if [[ $? -eq 255 ]]; then
      continue
    fi
    wait_failed="false"
    break
  done

  if [[ $wait_failed == "true" ]]; then
    echo "$failure_message"
    print_k8s_ack_controller_pod_logs
    exit 1
  fi
  k8s_controller_reload_credentials "$service_name"
}

# aws_wait_replication_group_deleted waits for supplied replication_group_id to be deleted
# aws_wait_replication_group_deleted requires 2 arguments
#     replication_group_id
#     error_message - message to print when wait is over with failure
aws_wait_replication_group_deleted() {
  if [[ $# -ne 2 ]]; then
    echo "FATAL: Wrong number of arguments passed to aws_wait_replication_group_deleted"
    echo "Usage: aws_wait_replication_group_deleted replication_group_id failure_message"
    exit 1
  fi
  local replication_group_id="$1"
  local failure_message="$2"
  local wait_failed="true"
  for i in $(seq 0 5); do
    k8s_controller_reload_credentials "$service_name"
    debug_msg "starting to wait for replication group: $replication_group_id to be deleted."
    $(daws elasticache wait replication-group-deleted --replication-group-id "$replication_group_id")
    if [[ $? -eq 255 ]]; then
      continue
    fi
    wait_failed="false"
    break
  done

  if [[ $wait_failed == "true" ]]; then
    echo "$failure_message"
    print_k8s_ack_controller_pod_logs
    exit 1
  fi
  k8s_controller_reload_credentials "$service_name"
}

# aws_get_replication_group_json returns the JSON description of the replication group of interest
# aws_get_replication_group_json requires 1 arguments:
#    replication_group_id
aws_get_replication_group_json() {
  if [[ $# -ne 1 ]]; then
    echo "FATAL: Wrong number of arguments passed to ${FUNCNAME[0]}"
    echo "${FUNCNAME[0]} replication_group_id"
    exit 1
  fi
  echo $(daws elasticache describe-replication-groups --replication-group-id "$1" | jq -r -e ".ReplicationGroups[0]")
}

# aws_get_rg_param_group asserts that the name of the parameter group associated with the provided replication group
#   matches the name of the expected parameter group
# aws_get_rg_param_group requires 2 arguments:
#   replication_group_id
#   expected_parameter_group_name
aws_assert_rg_param_group() {
  if [[ $# -ne 2 ]]; then
    echo "FATAL: Wrong number of arguments passed to ${FUNCNAME[0]}"
    echo "${FUNCNAME[0]} replication_group_id expected_parameter_group_name"
    exit 1
  fi

  local primary_cluster=$(aws_get_replication_group_json "$1" | jq -r -e ".MemberClusters[0]")
  local cluster_json=$(daws elasticache describe-cache-clusters --cache-cluster-id "$primary_cluster" | jq -r -e ".CacheClusters[0]")
  local param_group=$(echo $cluster_json | jq -r -e ".CacheParameterGroup .CacheParameterGroupName")
  if [[ "$param_group" != "$2" ]]; then
    echo "FAIL: expected replication group $1 to have parameter group $2. Actual: $param_group"
    exit 1
  fi
}

# aws_assert_replication_group_property compares the requested property, retrieved from the AWS CLI,
#   to the expected value of that property.
# aws_assert_replication_group_property requires 3 arguments:
#   replication_group_id
#   jq_filter – the property of interest, e.g. ".CacheNodeType"
#   expected_value
aws_assert_replication_group_property() {
  if [[ $# -ne 3 ]]; then
    echo "FATAL: Wrong number of arguments passed to ${FUNCNAME[0]}"
    echo "${FUNCNAME[0]} replication_group_id jq_filter expected_value"
    exit 1
  fi
  local actual_value=$(aws_get_replication_group_json "$1" | jq -r -e "$2")
  if [[ "$3" != "$actual_value" ]]; then
    echo "FAIL: property $2 for replication group $1 has value '$actual_value', but expected '$3'"
    print_k8s_ack_controller_pod_logs
    exit 1
  fi
}

# aws_assert_replication_group_status compares status of supplied replication_group_id with supplied status
# current status is retrieved from aws cli service api
# aws_assert_replication_group_status requires 2 arguments
#     replication_group_id
#     expected_status - expected status
# it depends on aws elasticache cli
aws_assert_replication_group_status() {
  if [[ $# -ne 2 ]]; then
    echo "FATAL: Wrong number of arguments passed to aws_assert_replication_group_status"
    echo "Usage: aws_assert_replication_group_status replication_group_id  expected_status"
    exit 1
  fi
  aws_assert_replication_group_property "$1" ".Status" "$2"
}

# k8s_get_rg_field retrieves the JSON of the requested status field
# k8s_get_rg_field requires 2 arguments:
#   replication_group_id
#   jq_filter – the status field of interest, e.g. ".status .nodeGroups[0] .nodeGroupMembers" for nodes in a shard
k8s_get_rg_field() {
  if [[ $# -ne 2 ]]; then
    echo "FATAL: Wrong number of arguments passed to ${FUNCNAME[0]}"
    echo "Usage: ${FUNCNAME[0]} replication_group_id jq_filter"
    exit 1
  fi
  echo $(kubectl get ReplicationGroup/"$1" -o json | jq -r -e "$2")
}

# k8s_assert_replication_group_status_property compares status of supplied replication_group_id with supplied status
# current status is retrieved from latest state of replication group in k8s cluster using kubectl
# k8s_assert_replication_group_status_property requires 3 arguments
#     replication_group_id
#     property_json_path - json path inside k8s crd status object. example: .description
#     expected_value - expected value of the property
k8s_assert_replication_group_status_property() {
  if [[ $# -ne 3 ]]; then
    echo "FATAL: Wrong number of arguments passed to k8s_assert_replication_group_status_property"
    echo "Usage: k8s_assert_replication_group_status_property replication_group_id property_json_path expected_value"
    exit 1
  fi
  local actual_value=$(k8s_get_rg_field "$1" ".status | $2")
  if [[ "$3" != "$actual_value" ]]; then
    echo "FAIL: property $2 for replication group $1 has value '$actual_value', but expected '$3'"
    print_k8s_ack_controller_pod_logs
    exit 1
  fi
}

# k8s_assert_replication_group_shard_count compares shard count of supplied replication_group_id with supplied count
# current status is retrieved from latest state of replication group in k8s cluster using kubectl
# k8s_assert_replication_group_shard_count requires 2 arguments
#     replication_group_id
#     expected_count - expected shard count
k8s_assert_replication_group_shard_count() {
  if [[ $# -ne 2 ]]; then
    echo "FATAL: Wrong number of arguments passed to k8s_assert_replication_group_shard_count"
    echo "Usage: k8s_assert_replication_group_shard_count replication_group_id expected_count"
    exit 1
  fi
  local actual_value=$(k8s_get_rg_field "$1" ".status .nodeGroups" | jq length)
  if [[ "$2" -ne "$actual_value" ]]; then
    echo "FAIL: expected $2 node groups in replication group $1, actual: $actual_value"
    print_k8s_ack_controller_pod_logs
    exit 1
  fi
}

# k8s_assert_replication_group_replica_count compares replica count of supplied replication_group_id with supplied count
# current status is retrieved from latest state of replication group in k8s cluster using kubectl
# k8s_assert_replication_group_replica_count requires 2 arguments
#     replication_group_id
#     expected_count - expected replica count
k8s_assert_replication_group_replica_count() {
  if [[ $# -ne 2 ]]; then
    echo "FATAL: Wrong number of arguments passed to k8s_assert_replication_group_replica_count"
    echo "Usage: k8s_assert_replication_group_replica_count replication_group_id expected_count"
    exit 1
  fi
  local node_group_size=$(k8s_get_rg_field "$1" ".status .nodeGroups[0] .nodeGroupMembers" | jq length)
  actual_replica_count=$(( node_group_size - 1 ))
  if [[ "$2" -ne "$actual_replica_count" ]]; then
    echo "FAIL: expected $2 replicas per node group for replication group $1, actual: $actual_replica_count"
    print_k8s_ack_controller_pod_logs
    exit 1
  fi
}

# k8s_assert_replication_group_total_node_count asserts the total number of nodes/clusters in the specified
#   replication group. The total node count should be (# shards) x (# replicas per shard + 1)
# k8s_assert_replication_group_total_node_count requires 2 arguments
#     replication_group_id
#     expected_count - expected total node count
k8s_assert_replication_group_total_node_count() {
  if [[ $# -ne 2 ]]; then
    echo "FATAL: Wrong number of arguments passed to ${FUNCNAME[0]}"
    echo "Usage: ${FUNCNAME[0]} replication_group_id expected_count"
    exit 1
  fi
  local actual_value=$(k8s_get_rg_field "$1" ".status .memberClusters" | jq length)
  if [[ "$2" != "$actual_value" ]]; then
    echo "FAIL: expected $2 total nodes for replication group $1, actual: $actual_value"
    print_k8s_ack_controller_pod_logs
    exit 1
  fi
}

# delete all replication groups in existing clusters and print a debug message
k8s_perform_rg_test_cleanup () {
  debug_msg "Cleaning up test replication groups..."
  kubectl delete ReplicationGroup --all 2>/dev/null
  assert_equal "0" "$?" "Expected success from kubectl delete but got $?" || exit 1
}

# assert_terminal_condition_true asserts that the terminal condition exists, has status "True", and
#   the message associated with the terminal condition matches the one provided. The assertions should pass
#   following an invalid operation (e.g. create RG with negative replica count, e.g. modify cluster mode
#   disabled RG from 1 to 2 shards)
# assert_terminal_condition_true requires 2 arguments
#   replication_group_id
#   expected_substring: a substring of the expected message associated with the terminal condition
assert_rg_terminal_condition_true() {
  if [[ $# -ne 2 ]]; then
    echo "FATAL: Wrong number of arguments passed to ${FUNCNAME[0]}"
    echo "Usage: ${FUNCNAME[0]} replication_group_id expected_substring"
    exit 1
  fi

  terminal_cond=$(k8s_get_rg_field "$1" ".status .conditions[]" | jq -r -e 'select(.type == "ACK.Terminal")')
  if [[ $? != 0 ]]; then
    echo "FAIL: expected replication group $1 to have a terminal condition"
    exit 1
  fi

  status=$(echo $terminal_cond | jq -r -e ".status")
  if [[ $status != "True" ]]; then
    echo "FAIL: expected status of terminal condition to be True for replication group $1"
    exit 1
  fi

  cond_msg=$(echo $terminal_cond | jq -r -e ".message")
  if [[ $cond_msg != *"$2"* ]]; then
    echo "FAIL: replication group $1 has terminal condition set True, but with unexpected message"
    exit 1
  fi
}

# check_rg_terminal_condition_true waits for a number of seconds (ideally after config application), then
#   periodically calls assert_rg_terminal_condition_true to ensure that the expected terminal condition
#   exists, is set True, has the proper message, and that the state of all of these properties is stable.
# check_rg_terminal_condition_true requires 2 arguments
#   replication_group_id
#   expected_substring: a substring of the expected message associated with the terminal condition
check_rg_terminal_condition_true() {
  if [[ $# -ne 2 ]]; then
    echo "FATAL: Wrong number of arguments passed to ${FUNCNAME[0]}"
    echo "Usage: ${FUNCNAME[0]} replication_group_id expected_substring"
    exit 1
  fi
  sleep 10 # allow time for terminal condition property to exist in conditions array

  # check all desired state periodically, should ensure state is stable
  for i in $(seq 0 14); do
    sleep 2
    assert_rg_terminal_condition_true "$1" "$2"
  done
}

# wait_and_assert_replication_group_available_status should be called after applying a yaml for replication group
#   creation to ensure the resource is available. It checks the underlying AWS resource directly but also checks the
#   availability of the resource via Kubernetes. If any of these checks fail the script will exit with a nonzero
#   error code.
# wait_and_assert_replication_group_available_status requires no direct arguments but requires rg_id and service_name
#   to be set to the name of the replication group of interest and "elasticache", respectively
wait_and_assert_replication_group_available_status() {
  sleep 5
  aws_wait_replication_group_available "$rg_id" "FAIL: expected replication group $rg_id to have been created in ${service_name}"
  aws_assert_replication_group_status "$rg_id" "available"
  sleep 35
  k8s_assert_replication_group_status_property "$rg_id" ".status" "available"
}