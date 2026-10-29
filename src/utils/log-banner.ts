import {readPackageSync} from 'read-pkg';

const logBanner = () => {
  const buildDate = process.env.BUILD_DATE ? new Date(process.env.BUILD_DATE) : undefined;
  const built = buildDate && !Number.isNaN(buildDate.getTime()) ? ` built ${buildDate.toLocaleDateString()}` : '';

  console.log(`LnnMusicBot ${readPackageSync().version}${built} (commit ${process.env.COMMIT_HASH ?? 'unknown'})`);
  console.log('\n');
};

export default logBanner;
