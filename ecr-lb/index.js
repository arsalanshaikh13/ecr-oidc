const express = require('express');
const path = require('path');
const os = require("os");
const { ECSClient, DescribeTasksCommand, DescribeContainerInstancesCommand } = require("@aws-sdk/client-ecs");

const app = express();
const PORT = 3200;

// ECS metadata endpoint (works in both Fargate & EC2)
const ECS_METADATA_URL = process.env.ECS_CONTAINER_METADATA_URI_V4 || process.env.ECS_CONTAINER_METADATA_URI;

// AWS SDK client
const ecs = new ECSClient({ region: process.env.AWS_REGION || "us-east-1" });

const osPlatform = os.platform() || "Unknown";

app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

app.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, 'views', 'index.html'));
});

// Health check endpoint
app.get("/health", (req, res) => {
  res.status(200).json({ status: "ok", message: "Service is healthy", uptime: process.uptime() });
});

app.get("/metadata", async (req, res) => {
  let instanceId = "Unknown";
  let taskId = "Unknown";
  let launchType = "local";
  let availabilityZone = "Unknown";

  try {
    // ECS Task Metadata
    if (ECS_METADATA_URL) {
      const response = await fetch(`${ECS_METADATA_URL}/task`);
      const taskMeta = await response.json();

      // Extract ECS Task ID
      if (taskMeta?.TaskARN) {
        taskId = taskMeta.TaskARN.split("/").pop();
      }

      if (taskMeta?.AvailabilityZone) {
        availabilityZone = taskMeta.AvailabilityZone;
      }

      launchType = taskMeta?.LaunchType || "Unknown"; // "EC2" or "FARGATE"

      // If EC2 launch type -> resolve EC2 instance ID
      if (taskMeta.LaunchType === "EC2") {
        const cluster = taskMeta.Cluster;
        const taskArn = taskMeta.TaskARN;

        // Describe Task to get ContainerInstanceARN
        const taskDesc = await ecs.send(
          new DescribeTasksCommand({ cluster, tasks: [taskArn] })
        );

        const containerInstanceArn = taskDesc.tasks?.[0]?.containerInstanceArn;

        if (containerInstanceArn) {
          // Describe Container Instance to get EC2 Instance ID
          const containerDesc = await ecs.send(
            new DescribeContainerInstancesCommand({
              cluster,
              containerInstances: [containerInstanceArn],
            })
          );

          instanceId = containerDesc.containerInstances?.[0]?.ec2InstanceId || "Unknown";
        }
      }
    }

    res.json({
      launchType,
      instanceId,
      taskId,
      osPlatform,
      availabilityZone
    });

  } catch (err) {
    console.error("Metadata fetch error:", err);
    res.status(500).json({ error: "Unable to fetch metadata" });
  }
});

app.listen(PORT, () => {
  console.log(`Server is running on http://localhost:${PORT}`);
});