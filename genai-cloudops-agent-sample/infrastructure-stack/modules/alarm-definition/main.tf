# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
resource oci_monitoring_alarm this {
  alarm_summary = "test_alarm for CPU Usage"
  compartment_id = var.compartment_ocid
  destinations = [
    var.stream_id
  ]
  display_name              = var.display_name
  evaluation_slack_duration = "PT3M"
  is_enabled                                    = "true"
  is_notifications_per_metric_dimension_enabled = "false"
  message_format                                = "RAW"
  metric_compartment_id                         = var.compartment_ocid
  metric_compartment_id_in_subtree              = "false"
  namespace                                     = "oci_computeagent"
  pending_duration                              = "PT1M"
  query                                         = "CpuUtilization[1m].mean() > 90"
  resolution = "1m"
  rule_name = "Critical-CpuUtilization-greater-than-90-Rule1"
  severity  = "CRITICAL"
}

