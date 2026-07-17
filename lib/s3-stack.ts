import * as cdk from 'aws-cdk-lib';
import * as s3 from 'aws-cdk-lib/aws-s3';

interface S3StackProps extends cdk.StackProps {
  instanceName: string;
  environment: string;
}

export class S3Stack extends cdk.Stack {
  constructor(scope: cdk.App, id: string, props: S3StackProps) {
    super(scope, id, props);

    const { instanceName, environment } = props;

    const bucket = new s3.Bucket(this, 'StorageBucket', {
      bucketName: `${instanceName}-${environment}-storage`,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    // Apply tags separately
    cdk.Tags.of(bucket).add('Name', `${instanceName}-${environment}-storage`);
    cdk.Tags.of(bucket).add('Environment', environment);
    cdk.Tags.of(bucket).add('ManagedBy', 'cdk');
  }
}
