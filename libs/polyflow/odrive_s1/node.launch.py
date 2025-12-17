import json
from launch import LaunchDescription
from launch_ros.actions import Node

def generate_launch_description():
    parameters = json.loads('{"joint":"6942143ad1dce07ccaa72647","control_mode":"position","limit.lower_position":0,"limit.upper_position":360,"limit.position_step":null,"limit.max_effort":0,"limit.effort_step":0.1,"limit.max_velocity":0,"limit.velocity_step":0.1}')
    configuration = json.loads('{"namespace":"/robot/base","rate_hz":150,"lifecycle":true}')
    inbound_connections = json.loads('[]')
    outbound_connections = json.loads('[]')
    env = {
        "POLYFLOW_NODE_ID": "694214dad1dce07ccaa7266e",
        "POLYFLOW_PARAMETERS": json.dumps(parameters),
        "POLYFLOW_CONFIGURATION": json.dumps(configuration),
        "POLYFLOW_INBOUND_CONNECTIONS": json.dumps(inbound_connections),
        "POLYFLOW_OUTBOUND_CONNECTIONS": json.dumps(outbound_connections),
    }

    return LaunchDescription([
        Node(
            package="odrive_s1",
            executable="odrive_s1_node",
            name="odrive_s1_node",
            output="screen",
            additional_env=env
        )
    ])