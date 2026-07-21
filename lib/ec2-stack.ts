import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
 
interface Ec2StackProps extends cdk.StackProps {
  instanceName: string;
  environment: string;
  ami: string;
  instanceType: string;
}
 
export class Ec2Stack extends cdk.Stack {
  constructor(scope: cdk.App, id: string, props: Ec2StackProps) {
    super(scope, id, props);
    const { instanceName, environment, ami, instanceType } = props;
 
    const vpc = ec2.Vpc.fromLookup(this, 'DefaultVpc', { isDefault: true });
 
    // Security group: SSH (for Harness CD deploy) + HTTP (to verify the app after deploy)
    const securityGroup = new ec2.SecurityGroup(this, 'WebInstanceSG', {
      vpc,
      description: `Security group for ${instanceName}-${environment}`,
      allowAllOutbound: true,
    });
    securityGroup.addIngressRule(ec2.Peer.anyIpv4(), ec2.Port.tcp(22), 'Allow SSH');
    securityGroup.addIngressRule(ec2.Peer.anyIpv4(), ec2.Port.tcp(80), 'Allow HTTP');
 
    // Key pair so Harness has SSH access; private key material lands in
    // AWS Systems Manager Parameter Store under /ec2/keypair/<key-pair-id>
    //const keyPair = new ec2.KeyPair(this, 'WebInstanceKeyPair', {
    // keyPairName: `${instanceName}-${environment}-key`,
    // });
   const keyPair = ec2.KeyPair.fromKeyPairName( this,
     'WebInstanceKeyPair',
     'dgwebapp-dev-dev-key'
   );
 
    const instance = new ec2.Instance(this, 'WebInstance', {
      vpc,
      machineImage: ec2.MachineImage.latestAmazonLinux2(),
      //machineImage: ec2.MachineImage.genericLinux({ [this.region]: ami }),
      instanceType: new ec2.InstanceType(instanceType),
      securityGroup,
      keyPair,
    });
 
    // Apply tags separately
    cdk.Tags.of(instance).add('Name', `${instanceName}-${environment}`);
    cdk.Tags.of(instance).add('Environment', environment);
    cdk.Tags.of(instance).add('ManagedBy', 'cdk');
 
    // Outputs consumed by the Harness pipeline's CD stage
    // (surfaced as IACM step "output variables" after Deploy)
    new cdk.CfnOutput(this, 'InstancePublicIp', {
      value: instance.instancePublicIp,
    });
    new cdk.CfnOutput(this, 'InstanceId', {
      value: instance.instanceId,
    });
    new cdk.CfnOutput(this, 'KeyPairName', { value: keyPair.keyPairName });
    new cdk.CfnOutput(this, 'KeyPairId', { value: 'key-043509c1b11820175' }); // static, known value — not derived from the construct

   
    //new cdk.CfnOutput(this, 'KeyPairId', {
      //value: keyPair.keyPairId,
    //});
    //new cdk.CfnOutput(this, 'KeyPairName', {
    //  value: keyPair.keyPairName,
  //  });
  }
}
