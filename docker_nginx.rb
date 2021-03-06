attr_accessor :last_requests, :last_request_time

category "Docker Nginx"

sample_interval 10

describe_samples do
  if container_filter = ENV['CS_DOCKER_NGINX_NAME_FILTER']
    container_ids = docker.ps(name_filter: container_filter)
    instance_id = ec2.instance_id
    container_ids.each do |c_id|
      total, reading, writing, waiting, requests = nil
      request_time = Time.now
      docker.exec(c_id, 'wget', '-qO', '-', '127.0.0.1/nginx_status').split("\n").each do |line|
        total = $1.to_i if line =~ /^Active connections:\s+(\d+)/
        if line =~ /^Reading:\s+(\d+).*Writing:\s+(\d+).*Waiting:\s+(\d+)/
          reading = $1.to_i
          writing = $2.to_i
          waiting = $3.to_i
        end
        requests = $3.to_i if line =~ /^\s+(\d+)\s+(\d+)\s+(\d+)/
      end

      if last_requests
        requests_per_second = (requests - last_requests) / (request_time - last_request_time)
      end
      self.last_requests = requests
      self.last_request_time = request_time

      rack_active = rack_queued = 0
      docker.exec(c_id, 'cat', '/proc/net/unix').split("\n").each do |line|
        if line =~ %r[/(unicorn|puma).sock$]
          _, _, _, _, _, _, inode, _ = line.split(' ')
          if inode == "0"
            rack_queued += 1
          else
            rack_active += 1
          end
        end
      end

      aggregation_dimensions = {}
      if aggregation_group = ENV['CS_AGGREGATION_GROUP']
        aggregation_dimensions[:group] = aggregation_group
      end
      opts = {
        aggregate: aggregation_dimensions,
        dimensions: {InstanceId: instance_id, ContainerId: c_id},
      }
      sample(**opts, name: "Active Connections", unit: "Count", value: total)
      sample(**opts, name: "Keep-Alive Connections", unit: "Count", value: waiting)
      sample(**opts, name: "Reading Connections", unit: "Count", value: reading)
      sample(**opts, name: "Writing Connections", unit: "Count", value: writing)
      sample(**opts, name: "Requests Handled", unit: "Count", value: requests)
      sample(**opts, name: "Request Throughput", unit: "Count/Second", value: requests_per_second)

      opts[:dimensions] = {ClusterName: ENV['ECS_CLUSTER']}
      sample(**opts, name: "Active Rack Connections", unit: "Count", value: rack_active,
          storage_resolution: 1)
      sample(**opts, name: "Queued Rack Connections", unit: "Count", value: rack_queued,
          storage_resolution: 1)
    end
  end
end
