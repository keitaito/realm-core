#!groovy

try {
  def gitTag
  def gitSha
  def version
  def dependencies
  def isPublishingRun
  def isPublishingLatestRun

  timeout(time: 1, unit: 'HOURS') {
    stage('gather-info') {
      node {
        checkout([
          $class: 'GitSCM',
          branches: scm.branches,
          gitTool: 'native git',
          extensions: scm.extensions + [[$class: 'CleanCheckout']],
          userRemoteConfigs: scm.userRemoteConfigs
        ])
        stash includes: '**', name: 'core-source'

        dependencies = readProperties file: 'dependencies.list'
        echo "VERSION: ${dependencies.VERSION}"

        gitTag = readGitTag()
        gitSha = readGitSha()
        version = get_version()
        echo "tag: ${gitTag}"
        if (gitTag == "") {
          echo "No tag given for this build"
          setBuildName(gitSha)
        } else {
          if (gitTag != "v${dependencies.VERSION}") {
            def message = "Git tag '${gitTag}' does not match v${dependencies.VERSION}"
            echo message
            throw new IllegalStateException(message)
          } else {
            echo "Building release: '${gitTag}'"
            setBuildName("Tag ${gitTag}")
          }
        }
      }

      isPublishingRun = gitTag != ""
      echo "Publishing Run: ${isPublishingRun}"

      isPublishingLatestRun = ['master'].contains(env.BRANCH_NAME)

      rpmVersion = dependencies.VERSION.replaceAll("-", "_")
      echo "rpm version: ${rpmVersion}"

      if (['master'].contains(env.BRANCH_NAME)) {
        // If we're on master, instruct the docker image builds to push to the
        // cache registry
        env.DOCKER_PUSH = "1"
      }
    }

    stage('check') {
      parallelExecutors = [
        checkLinuxRelease: doBuildInDocker('check'),
        checkLinuxDebug: doBuildInDocker('check-debug'),
        buildCocoa: doBuildCocoa(isPublishingRun, isPublishingLatestRun),
        buildNodeLinux: doBuildNodeInDocker(isPublishingRun, isPublishingLatestRun),
        buildNodeOsx: doBuildNodeInOsx(isPublishingRun, isPublishingLatestRun),
        buildDotnetOsx: doBuildDotNetOsx(isPublishingRun, isPublishingLatestRun),
        buildAndroid: doBuildAndroid(isPublishingRun),
        buildWindows: doBuildWindows(version, isPublishingRun),
        buildOsxDylibs: doBuildOsxDylibs(isPublishingRun, isPublishingLatestRun),
        addressSanitizer: doBuildInDocker('jenkins-pipeline-address-sanitizer')
        //threadSanitizer: doBuildInDocker('jenkins-pipeline-thread-sanitizer')
      ]

      if (env.CHANGE_TARGET) {
        parallelExecutors['diffCoverage'] = buildDiffCoverage()
      }

      parallel parallelExecutors
    }

    stage('build-packages') {
      parallel(
        generic: doBuildPackage('generic', 'tgz'),
        centos7: doBuildPackage('centos-7', 'rpm'),
        centos6: doBuildPackage('centos-6', 'rpm'),
        ubuntu1604: doBuildPackage('ubuntu-1604', 'deb')
      )
    }

    if (isPublishingRun) {
      stage('publish-packages') {
        parallel(
          generic: doPublishGeneric(),
          centos7: doPublish('centos-7', 'rpm', 'el', 7),
          centos6: doPublish('centos-6', 'rpm', 'el', 6),
          ubuntu1604: doPublish('ubuntu-1604', 'deb', 'ubuntu', 'xenial'),
          others: doPublishLocalArtifacts()
        )
      }
    }
  }
} catch(Exception e) {
  e.printStackTrace()
  throw e
}

def buildDockerEnv(name) {
  docker.withRegistry("https://012067661104.dkr.ecr.eu-west-1.amazonaws.com", "ecr:eu-west-1:aws-ci-user") {
    env.DOCKER_REGISTRY = '012067661104.dkr.ecr.eu-west-1.amazonaws.com'
    sh "./packaging/docker_build.sh $name ."
  }

  return docker.image(name)
}

def doBuildCocoa(def isPublishingRun, def isPublishingLatestRun) {
  return {
    node('osx_vegas') {
      getArchive()

      try {
        withEnv([
          'PATH=$PATH:/usr/local/bin',
          'REALM_ENABLE_ENCRYPTION=yes',
          'REALM_ENABLE_ASSERTIONS=yes',
          'MAKEFLAGS=CFLAGS_DEBUG\\=-Oz',
          'UNITTEST_SHUFFLE=1',
          'UNITTEST_REANDOM_SEED=random',
          'UNITTEST_XML=1',
          'UNITTEST_THREADS=1',
          'DEVELOPER_DIR=/Applications/Xcode-7.3.1.app/Contents/Developer/'
        ]) {
            sh '''
              dir=$(pwd)
              sh build.sh config $dir/install
              sh build.sh build-cocoa
              sh build.sh check-debug

              # Repack the release with just what we need so that it is not a 1 GB download
              version=$(sh build.sh get-version)
              tmpdir=$(mktemp -d /tmp/$$.XXXXXX) || exit 1
              (
                  cd $tmpdir || exit 1
                  unzip -qq "$dir/core-$version.zip" || exit 1

                  # We only need an armv7s slice for CocoaPods, and the podspec never uses
                  # the debug build of core, so remove that slice
                  lipo -remove armv7s core/librealm-ios-dbg.a -o core/librealm-ios-dbg.a

                  tar cf "$dir/realm-core-$version.tar.xz" --xz core || exit 1
              )
              rm -rf "$tmpdir" || exit 1

              cp realm-core-*.tar.xz realm-core-latest.tar.xz
            '''

            if (isPublishingRun) {
              stash includes: '*core-*.*.*.tar.xz', name: 'cocoa-package'
            }
	    archiveArtifacts artifacts: '*core-*.*.*.tar.xz'

            sh 'sh build.sh clean'
        }
      } finally {
        collectCompilerWarnings('clang', true)
        recordTests('check-debug-cocoa')
        withCredentials([[$class: 'FileBinding', credentialsId: 'c0cc8f9e-c3f1-4e22-b22f-6568392e26ae', variable: 's3cfg_config_file']]) {
          if (isPublishingLatestRun) {
            sh 's3cmd -c $s3cfg_config_file put realm-core-latest.tar.xz s3://static.realm.io/downloads/core/'
          }
        }
      }
    }
  }
}

def doBuildDotNetOsx(def isPublishingRun, def isPublishingLatestRun) {
  return {
    node('osx_vegas') {
      getArchive()

      try {
        withEnv([
          'PATH=$PATH:/usr/local/bin',
          'DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer',
          'REALM_ENABLE_ENCRYPTION=yes',
          'REALM_ENABLE_ASSERTIONS=yes',
          'MAKEFLAGS=CFLAGS_DEBUG\\=-Oz',
          'UNITTEST_SHUFFLE=1',
          'UNITTEST_REANDOM_SEED=random',
          'UNITTEST_XML=1',
          'UNITTEST_THREADS=1'
        ]) {
            sh '''
              dir=$(pwd)
              sh build.sh config $dir/install
              sh build.sh build-dotnet-cocoa

              # Repack the release with just what we need so that it is not a 1 GB download
              version=$(sh build.sh get-version)
              tmpdir=$(mktemp -d /tmp/$$.XXXXXX) || exit 1
              (
                  cd $tmpdir || exit 1
                  unzip -qq "$dir/realm-core-dotnet-cocoa-$version.zip" || exit 1

                  # We only need an armv7s slice for CocoaPods, and the podspec never uses
                  # the debug build of core, so remove that slice
                  lipo -remove armv7s core/librealm-ios-no-bitcode-dbg.a -o core/librealm-ios-no-bitcode-dbg.a

                  tar cjf "$dir/realm-core-dotnet-cocoa-$version.tar.bz2" core || exit 1
              )
              rm -rf "$tmpdir" || exit 1

              cp realm-core-dotnet-cocoa-*.tar.bz2 realm-core-dotnet-cocoa-latest.tar.bz2
            '''
            if (isPublishingRun) {
              stash includes: '*core-*.*.*.tar.bz2', name: 'dotnet-package'
            }
            archiveArtifacts artifacts: '*core-*.*.*.tar.bz2'

            sh 'sh build.sh clean'
        }
      } finally {
        collectCompilerWarnings('clang', true)
        withCredentials([[$class: 'FileBinding', credentialsId: 'c0cc8f9e-c3f1-4e22-b22f-6568392e26ae', variable: 's3cfg_config_file']]) {
          if (isPublishingLatestRun) {
            sh 's3cmd -c $s3cfg_config_file put --multipart-chunk-size-mb 5 realm-core-dotnet-cocoa-latest.tar.bz2 s3://static.realm.io/downloads/core/'
          }
        }
      }
    }
  }
}


def doBuildInDocker(String command) {
  return {
    node('docker') {
      getArchive()

      def buildEnv = buildDockerEnv('ci/realm-core:snapshot')
      def environment = environment()
      withEnv(environment) {
        buildEnv.inside {
          sh 'sh build.sh config'
          try {
              sh "sh build.sh ${command}"
          } finally {
            collectCompilerWarnings('gcc', true)
            recordTests(command)
          }
        }
      }
    }
  }
}

def doBuildWindows(String version, boolean isPublishingRun) {
    return {
        node('windows') {
            getArchive()
            try {
              bat "\"${tool 'msbuild'}\" \"Visual Studio\\Realm.sln\" /p:Configuration=Debug /p:Platform=\"Win32\""
              bat "\"${tool 'msbuild'}\" \"Visual Studio\\Realm.sln\" /p:Configuration=\"Static lib, release\" /p:Platform=\"Win32\""
              bat "\"${tool 'msbuild'}\" \"Visual Studio\\Realm.sln\" /p:Configuration=\"Static lib, debug\" /p:Platform=\"Win32\""
              dir('Visual Studio') {
                stash includes: 'lib/*.lib', name: 'windows-libs'
              }
              dir('src') {
                stash includes: '**/*.hpp', name: 'windows-includes'
              }
              dir('packaging-tmp') {
                unstash 'windows-libs'
                dir('include') {
                  unstash 'windows-includes'
                }
              }
              zip dir:'packaging-tmp', zipFile:"realm-core-windows-${version}.zip", archive:true
              if (isPublishingRun) {
                stash includes:"realm-core-windows-${version}.zip", name:'windows-package'
              }
            } finally {
              collectCompilerWarnings('msbuild', false)
            }
        }
    }
}

def buildDiffCoverage() {
  return {
    node('docker') {
      checkout([
        $class: 'GitSCM',
        branches: scm.branches,
        gitTool: 'native git',
        extensions: scm.extensions + [[$class: 'CleanCheckout']],
        userRemoteConfigs: scm.userRemoteConfigs
      ])

      def buildEnv = buildDockerEnv('ci/realm-core:snapshot')
      def environment = environment()
      withEnv(environment) {
        buildEnv.inside {
          sh 'sh build.sh config'
          sh 'sh build.sh jenkins-pipeline-coverage'

          sh 'mkdir -p coverage'
          sh "diff-cover gcovr.xml " +
            "--compare-branch=origin/${env.CHANGE_TARGET} " +
            "--html-report coverage/diff-coverage-report.html " +
            "| grep -F Coverage: " +
            "| head -n 1 " +
            "> diff-coverage"

          publishHTML(target: [
              allowMissing: false,
              alwaysLinkToLastBuild: false,
              keepAll: true,
              reportDir: 'coverage',
              reportFiles: 'diff-coverage-report.html',
              reportName: 'Diff Coverage'
          ])

          def coverageResults = readFile('diff-coverage')

          withCredentials([[$class: 'StringBinding', credentialsId: 'bot-github-token', variable: 'githubToken']]) {
              sh "curl -H \"Authorization: token ${env.githubToken}\" " +
                 "-d '{ \"body\": \"${coverageResults}\\n\\nPlease check your coverage here: ${env.BUILD_URL}Diff_Coverage\"}' " +
                 "\"https://api.github.com/repos/realm/realm-core/issues/${env.CHANGE_ID}/comments\""
          }
        }
      }
    }
  }
}

def doBuildNodeInDocker(def isPublishingRun, def isPublishingLatestRun) {
  return {
    node('docker') {
      getArchive()

      def buildEnv = buildDockerEnv('ci/realm-core:snapshot')
      def environment = ['REALM_ENABLE_ENCRYPTION=yes', 'REALM_ENABLE_ASSERTIONS=yes']
      withEnv(environment) {
        buildEnv.inside {
          sh 'sh build.sh config'
          try {
              sh 'sh build.sh build-node-package'
              sh 'cp realm-core-node-*.tar.gz realm-core-node-linux-latest.tar.gz'
              if (isPublishingRun) {
                stash includes: '*realm-core-node-linux-*.*.*.tar.gz', name: 'node-linux-package'
              }
              archiveArtifacts artifacts: '*realm-core-node-linux-*.*.*.tar.gz'
              withCredentials([[$class: 'FileBinding', credentialsId: 'c0cc8f9e-c3f1-4e22-b22f-6568392e26ae', variable: 's3cfg_config_file']]) {
                if (isPublishingLatestRun) {
                  sh 's3cmd -c $s3cfg_config_file put realm-core-node-linux-latest.tar.gz s3://static.realm.io/downloads/core/'
                }
              }
          } finally {
            collectCompilerWarnings('gcc', true)
          }
        }
      }
    }
  }
}

def doBuildNodeInOsx(def isPublishingRun, def isPublishingLatestRun) {
  return {
    node('osx_vegas') {
      getArchive()

      def environment = ['REALM_ENABLE_ENCRYPTION=yes', 'REALM_ENABLE_ASSERTIONS=yes']
      withEnv(environment) {
        sh 'sh build.sh config'
        try {
          sh 'sh build.sh build-node-package'
          sh 'cp realm-core-node-*.tar.gz realm-core-node-osx-latest.tar.gz'
          if (isPublishingRun) {
            stash includes: '*realm-core-node-osx-*.*.*.tar.gz', name: 'node-cocoa-package'
          }
          archiveArtifacts artifacts: '*realm-core-node-osx-*.*.*.tar.gz'

          sh 'sh build.sh clean'

          withCredentials([[$class: 'FileBinding', credentialsId: 'c0cc8f9e-c3f1-4e22-b22f-6568392e26ae', variable: 's3cfg_config_file']]) {
            if (isPublishingLatestRun) {
              sh 's3cmd -c $s3cfg_config_file put realm-core-node-osx-latest.tar.gz s3://static.realm.io/downloads/core/'
            }
          }
        } finally {
          collectCompilerWarnings('clang', true)
        }
      }
    }
  }
}

def doBuildOsxDylibs(def isPublishingRun, def isPublishingLatestRun) {
  return {
    node('osx_vegas') {
      getSourceArchive()
      def version = get_version()

      def environment = ['REALM_ENABLE_ENCRYPTION=yes', 'REALM_ENABLE_ASSERTIONS=yes', 'UNITTEST_SHUFFLE=1',
        'UNITTEST_XML=1', 'UNITTEST_THREADS=1']
      withEnv(environment) {
        sh 'sh build.sh config'
        try {
          sh '''
            sh build.sh build
            sh build.sh check-debug
          '''

          dir('src/realm') {
            sh "zip --symlink ../../realm-core-dylib-osx-${version}.zip librealm*.dylib"
          }

          sh 'cp realm-core-dylib-osx-*.zip realm-core-dylib-osx-latest.zip'

          if (isPublishingRun) {
            stash includes: '*realm-core-dylib-osx-*.*.*.zip', name: 'dylib-osx-package'
          }
          archiveArtifacts artifacts: '*realm-core-dylib-osx-*.*.*.zip'

          sh 'sh build.sh clean'

          withCredentials([[$class: 'FileBinding', credentialsId: 'c0cc8f9e-c3f1-4e22-b22f-6568392e26ae', variable: 's3cfg_config_file']]) {
            if (isPublishingLatestRun) {
              sh 's3cmd -c $s3cfg_config_file put realm-core-dylib-osx-latest.zip s3://static.realm.io/downloads/core/'
            }
          }
        } finally {
          collectCompilerWarnings('clang', true)
        }
      }
    }
  }
}

def doBuildAndroid(def isPublishingRun) {
    def target = 'build-android'
    def buildName = "android-${target}-with-encryption"

    def environment = environment()
    environment << "REALM_ENABLE_ENCRYPTION=yes"
    environment << "PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/sbin:/bin:/usr/local/bin:/opt/android-sdk-linux/tools:/opt/android-sdk-linux/platform-tools:/opt/android-ndk-r10e"
    environment << "ANDROID_NDK_HOME=/opt/android-ndk-r10e"

    return {
        node('fastlinux') {
          ws('/tmp/core-android') {
            getArchive()

            withEnv(environment) {
              sh "sh build.sh config '${pwd()}/install'"
              sh "sh build.sh ${target}"
            }
            if (isPublishingRun) {
              stash includes: 'realm-core-android-*.tar.gz', name: 'android-package'
            }
            archiveArtifacts artifacts: 'realm-core-android-*.tar.gz'

            dir('test/android') {
                sh '$ANDROID_HOME/tools/android update project -p . --target android-9'
                environment << "NDK_PROJECT_PATH=${pwd()}"
                withEnv(environment) {
                    dir('jni') {
                        sh "${env.ANDROID_NDK_HOME}/ndk-build V=1"
                    }
                    sh 'ant debug'
                    dir('bin') {
                        stash includes: 'NativeActivity-debug.apk', name: 'android'
                    }
                }
            }
            collectCompilerWarnings('gcc', true)
          }
        }

        node('android-hub') {
            sh 'rm -rf *'
            unstash 'android'

            sh 'adb devices | tee devices.txt'
            def adbDevices = readFile('devices.txt')
            def devices = getDeviceNames(adbDevices)

            if (!devices) {
                throw new IllegalStateException('No devices were found')
            }

            def device = devices[0] // Run the tests only on one device

            timeout(10) {
                sh """
                set -ex
                adb -s ${device} uninstall io.realm.coretest
                adb -s ${device} install NativeActivity-debug.apk
                adb -s ${device} logcat -c
                adb -s ${device} shell am start -a android.intent.action.MAIN -n io.realm.coretest/android.app.NativeActivity
                """

                sh """
                set -ex
                prefix="The XML file is located in "
                while [ true ]; do
                    sleep 10
                    line=\$(adb -s ${device} logcat -d -s native-activity 2>/dev/null | grep -m 1 -oE "\$prefix.*\\\$" | tr -d "\r")
                    if [ ! -z "\${line}" ]; then
                    	xml_file="\$(echo \$line | cut -d' ' -f7)"
                        adb -s ${device} pull "\$xml_file"
                        adb -s ${device} shell am force-stop io.realm.coretest
                    	break
                    fi
                done
                mkdir -p test
                cp unit-test-report.xml test/unit-test-report.xml
                """
            }
            recordTests('android-device')
        }
    }
}

def recordTests(tag) {
    def tests = readFile('test/unit-test-report.xml')
    def modifiedTests = tests.replaceAll('realm-core-tests', tag)
    writeFile file: 'test/modified-test-report.xml', text: modifiedTests
    junit 'test/modified-test-report.xml'
}

def collectCompilerWarnings(compiler, fail) {
    def parserName
    if (compiler == 'gcc') {
        parserName = 'GNU Make + GNU C Compiler (gcc)'
    } else if ( compiler == 'clang' ) {
        parserName = 'Clang (LLVM based)'
    } else if ( compiler == 'msbuild' ) {
        parserName = 'MSBuild'
    }
    step([
        $class: 'WarningsPublisher',
        canComputeNew: false,
        canResolveRelativePaths: false,
        consoleParsers: [[parserName: parserName]],
        defaultEncoding: '',
        excludePattern: '',
        unstableTotalAll: fail?'0':'',
        healthy: '',
        includePattern: '',
        messagesPattern: '',
        unHealthy: ''
    ])
}

def environment() {
    return [
    "REALM_MAX_BPNODE_SIZE_DEBUG=4",
    "UNITTEST_SHUFFLE=1",
    "UNITTEST_RANDOM_SEED=random",
    "UNITTEST_THREADS=1",
    "UNITTEST_XML=1"
    ]
}

def readGitTag() {
  sh "git describe --exact-match --tags HEAD | tail -n 1 > tag.txt 2>&1 || true"
  def tag = readFile('tag.txt').trim()
  return tag
}

def readGitSha() {
  sh "git rev-parse HEAD | cut -b1-8 > sha.txt"
  def sha = readFile('sha.txt').readLines().last().trim()
  return sha
}

def get_version() {
  def dependencies = readProperties file: 'dependencies.list'
  def gitTag = readGitTag()
  def gitSha = readGitSha()
  if (gitTag == "") {
    return "${dependencies.VERSION}-g${gitSha}"
  }
  else {
    return "${dependencies.VERSION}"
  }
}

@NonCPS
def getDeviceNames(String commandOutput) {
  def deviceNames = []
  def lines = commandOutput.split('\n')
  for (i = 0; i < lines.size(); ++i) {
    if (lines[i].contains('\t')) {
      deviceNames << lines[i].split('\t')[0].trim()
    }
  }
  return deviceNames
}

def doBuildPackage(distribution, fileType) {
  return {
    node('docker') {
      getSourceArchive()

      docker.withRegistry("https://012067661104.dkr.ecr.eu-west-1.amazonaws.com", "ecr:eu-west-1:aws-ci-user") {
        env.DOCKER_REGISTRY = '012067661104.dkr.ecr.eu-west-1.amazonaws.com'
        withCredentials([[$class: 'StringBinding', credentialsId: 'packagecloud-sync-devel-master-token', variable: 'PACKAGECLOUD_MASTER_TOKEN']]) {
          sh "sh packaging/package.sh ${distribution}"
        }
      }

      dir('packaging/out') {
        archiveArtifacts artifacts: "${distribution}/*.${fileType}"
        stash includes: "${distribution}/*.${fileType}", name: "packages-${distribution}"
      }
    }
  }
}

def doPublish(distribution, fileType, distroName, distroVersion) {
  return {
    node {
      getSourceArchive()
      packaging = load './packaging/publish.groovy'

      dir('packaging/out') {
        unstash "packages-${distribution}"
        dir(distribution) {
          packaging.uploadPackages('sync-devel', fileType, distroName, distroVersion, "*.${fileType}")
        }
      }
    }
  }
}

def doPublishGeneric() {
  return {
    node {
      getSourceArchive()
      def version = get_version()
      def topdir = pwd()
      dir('packaging/out') {
        unstash "packages-generic"
      }
      dir("core/v${version}/linux") {
        sh "mv ${topdir}/packaging/out/generic/realm-core-*.tgz ./realm-core-${version}.tgz"
      }

      step([
        $class: 'S3BucketPublisher',
        dontWaitForConcurrentBuildCompletion: false,
        entries: [[
          bucket: 'realm-ci-artifacts',
          excludedFile: '',
          flatten: false,
          gzipFiles: false,
          managedArtifacts: false,
          noUploadOnFailure: true,
          selectedRegion: 'us-east-1',
          sourceFile: "core/v${version}/linux/*.tgz",
          storageClass: 'STANDARD',
          uploadFromSlave: false,
          useServerSideEncryption: false
        ]],
        profileName: 'hub-jenkins-user',
        userMetadata: []
      ])
    }
  }
}

def doPublishLocalArtifacts() {
  // TODO create a Dockerfile for an image only containing s3cmd
  return {
    node('aws') {
      deleteDir()
      unstash 'cocoa-package'
      unstash 'dotnet-package'
      unstash 'node-linux-package'
      unstash 'node-cocoa-package'
      unstash 'android-package'
      unstash 'dylib-osx-package'
      unstash 'windows-package'

      withCredentials([[$class: 'FileBinding', credentialsId: 'c0cc8f9e-c3f1-4e22-b22f-6568392e26ae', variable: 's3cfg_config_file']]) {
        sh 'find . -type f -name "*.tar.*" -maxdepth 1 -exec s3cmd -c $s3cfg_config_file put {} s3://static.realm.io/downloads/core/ \\;'
        sh 'find . -type f -name "*.zip" -maxdepth 1 -exec s3cmd -c $s3cfg_config_file put {} s3://static.realm.io/downloads/core/ \\;'
      }
    }
  }
}

def setBuildName(newBuildName) {
  currentBuild.displayName = "${currentBuild.displayName} - ${newBuildName}"
}

def getArchive() {
    deleteDir()
    unstash 'core-source'
}

def getSourceArchive() {
  checkout scm
  sh 'git clean -ffdx -e .????????'
  sh 'git submodule update --init'
}
