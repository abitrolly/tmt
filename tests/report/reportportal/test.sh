#!/bin/bash
. /usr/share/beakerlib/beakerlib.sh || exit 1

TOKEN=$TMT_PLUGIN_REPORT_REPORTPORTAL_TOKEN
URL=$TMT_PLUGIN_REPORT_REPORTPORTAL_URL
PROJECT="$(yq -r .report.project 'data/plan.fmf')"
ARTIFACTS=$TMT_REPORT_ARTIFACTS_URL

PLAN_PREFIX='/plan'
PLAN_STATUS='FAILED'
TEST_PREFIX='/test'
declare -A test=([1,'uuid']="" [1,'name']='/bad'   [1,'status']='FAILED'
                 [2,'uuid']="" [2,'name']='/good'  [2,'status']='PASSED'
                 [3,'uuid']="" [3,'name']='/weird' [3,'status']='FAILED')
DIV="|"

##
# Read and verify reported launch name, id and uuid from $rlRun_LOG
#
# GLOBALS:
# << $launch_name
# >> $launch_uuid, $launch_id
#
function foo_launch(){
    rlLog "Verify and get launch data"

    rlAssertGrep "launch: $launch_name" $rlRun_LOG
    launch_uuid=$(rlRun "grep -A1 'launch:' $rlRun_LOG | tail -n1 | awk '{print \$NF}' ")
    regex='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    if [[ ! $launch_uuid =~ $regex ]]; then
        launch_uuid=$(rlRun "grep -A2 'launch:' $rlRun_LOG | tail -n1 | awk '{print \$NF}' ")
    fi

    rlAssertNotEquals "Assert the launch uuid is not empty" "$launch_uuid" ""
    launch_id=$(rlRun "grep 'url:' $rlRun_LOG | awk '{print \$NF}' | xargs basename")
    rlAssertNotEquals "Assert the launch id is not empty" "$launch_id" ""
}

##
# Read and verify reported suite name and uuid from $rlRun_LOG
#
# GLOBALS:
# << $suite_name
# >> $suite_uuid, $suite_id
function foo_suite(){
    rlLog "Verify and get suite data"

    rlAssertGrep "suite: $suite_name" $rlRun_LOG
    suite_uuid=$(rlRun "grep -A1 'launch:' $rlRun_LOG | tail -n1 | awk '{print \$NF}' ")
    rlAssertNotEquals "Assert the launch uuid is not empty" "$suite_uuid" ""
}

##
# Read and verify reported test names and uuids from $rlRun_LOG
#
# GLOBALS:
# >> $test_uuid[1..3], $test_fullname[1..3]
function foo_tests(){
    rlLog "Verify and get test data"

    for i in {1..3}; do
        test_fullname[$i]=${TEST_PREFIX}${test[$i,'name']}

        rlAssertGrep "test: ${test_fullname[$i]}" $rlRun_LOG
        test_uuid[$i]=$(rlRun "grep -m$i -A1 'test:' $rlRun_LOG | tail -n1 | awk '{print \$NF}' ")
        rlAssertNotEquals "Assert the test$i uuid is not empty" "{$test_uuid[$i]}" ""
        test[$i,'uuid']=${test_uuid[$i]}
    done
}

function rest_api(){

    rlLog "REST API $1 $2"
    response=$(curl --write-out "$DIV%{http_code}" --silent -X $1 $2 -H  "accept: */*" -H  "Authorization: bearer $TOKEN")

    response_code=${response##*"$DIV"}
    response=${response%"$DIV"*}
    if [[ $response_code -ge 300 ]]; then
        rlFail "Request responded with an error: $response"
    fi

    echo "$response"
}


rlJournalStart
    rlPhaseStartSetup
        rlRun "pushd data"
        rlRun "run=$(mktemp -d)" 0 "Create run workdir"
        rlRun "set -o pipefail"
        if [[ -z "$TOKEN" ||  -z "$URL" || -z "$PROJECT" ]]; then
            rlFail "URL, TOKEN and PROJECT must be defined properly" || rlDie
        fi
    rlPhaseEnd

    echo -e "\n\n\n::   PART 1\n"

    rlPhaseStartTest "Core Functionality"
        launch_name=$PLAN_PREFIX
        launch_status=$PLAN_STATUS
        rlRun -s "tmt run --id $run --verbose --all" 2

        rlAssertGrep "url: http.*redhat.com.ui/#${PROJECT}/launches/all/[0-9]{4}" $rlRun_LOG -Eq
        foo_launch  # >> $launch_uuid, $launch_id
        foo_tests   # >> $test_uuid[1..3], $test_fullname[1..3]
    rlPhaseEnd


    rlPhaseStartTest "Core Functionality - DEFAULT SETUP"

        rlLogInfo "Get info about the launch"
        # REST API GET | launch-controller (uuid)
        response=$(rest_api GET "$URL/api/v1/$PROJECT/launch/uuid/$launch_uuid")
        rlAssertEquals "Assert the URL ID of launch is correct" "$(echo $response | jq -r '.id')" "$launch_id"
        rlAssertEquals "Assert the name of launch is correct" "$(echo $response | jq -r '.name')" "$launch_name"
        rlAssertEquals "Assert the status of launch is correct" "$(echo $response | jq -r '.status')" "$launch_status"
        plan_summary=$(yq -r '.summary' plan.fmf)
        if [[ -z $ARTIFACTS ]]; then
                rlAssertEquals "Assert the description of launch is correct" "$(echo $response | jq -r '.description')" "$plan_summary"
        else
            if [[ $plan_summary == "null" ]]; then
            rlAssertEquals "Assert the description of launch is correct" "$(echo $response | jq -r '.description')" "$ARTIFACTS"
            else
            rlAssertEquals "Assert the description of launch is correct" "$(echo $response | jq -r '.description')" "$plan_summary, $ARTIFACTS"
            fi
        fi


        echo ""
        # Check all the launch attributes
        rl_message="Test attributes of the launch (context)"
        echo "$response" | jq -r ".attributes" > tmp_attributes.json && rlPass "$rl_message" || rlFail "$rl_message"
        length=$(yq -r ".context | length" plan.fmf)
        for ((item_index=0; item_index<$length; item_index++ )); do
            key=$(yq -r ".context | keys | .[$item_index]" plan.fmf)
            value=$(yq -r ".context.$key" plan.fmf)
            rlAssertGrep "$key" tmp_attributes.json -A1 > tmp_attributes_selection
            rlAssertGrep "$value" tmp_attributes_selection
        done
        rm tmp_attributes*

        for i in {1..3}; do
            echo ""
            test_name[$i]=${test[$i,'name']}
            test_name=${test_name[$i]}
            test_fullname=${test_fullname[$i]}
            test_uuid=${test_uuid[$i]}
            test_status[$i]=${test[$i,'status']}
            test_status=${test_status[$i]}

            rlLogInfo "Get info about the test item $test_name"
            # REST API GET | test-item-controller (uuid)
            response=$(rest_api GET "$URL/api/v1/$PROJECT/item/uuid/$test_uuid")
            test_id=$(echo $response | jq -r '.id')
            rlAssertNotEquals "Assert the test id is not empty" "$test_id" ""
            rlAssertEquals "Assert the name is correct" "$(echo $response | jq -r '.name')" "$test_fullname"
            rlAssertEquals "Assert the status is correct" "$(echo $response | jq -r '.status')" "$test_status"
            test_description=$(yq -r ".\"$test_name\".summary" test.fmf)
            rlAssertEquals "Assert the description is correct" "$(echo $response | jq -r '.description')" "$test_description"
            test_case_id=$(yq -r ".\"$test_name\".id" test.fmf)
            [[ $test_case_id != null ]] && rlAssertEquals "Assert the testCaseId is correct" "$(echo $response | jq -r '.testCaseId')" "$test_case_id"

            for jq_element in attributes parameters; do

                # Check all the common test attributes/parameters
                [[ $jq_element == attributes ]] && fmf_label="context"
                [[ $jq_element == parameters ]] && fmf_label="environment"
                rlLogInfo "Check the $jq_element for test $test_name ($fmf_label)"
                echo "$response" | jq -r ".$jq_element" > tmp_attributes.json || rlFail "$jq_element listing into tmp_attributes.json"
                length=$(yq -r ".$fmf_label | length" plan.fmf)
                for ((item_index=0; item_index<$length; item_index++ )); do
                    key=$(yq -r ".$fmf_label | keys | .[$item_index]" plan.fmf)
                    value=$(yq -r ".$fmf_label.$key" plan.fmf)
                    rlAssertGrep "$key" tmp_attributes.json -A1 > tmp_attributes_selection
                    rlAssertGrep "$value" tmp_attributes_selection
                done

                # Check the rarities in the test attributes/parameters
                if [[ $jq_element == attributes ]]; then
                    key="contact"
                    value="$(yq -r ".\"$test_name\".$key" test.fmf)"
                    if [[ $value != null ]]; then
                        rlAssertGrep "$key" tmp_attributes.json -A1 > tmp_attributes_selection
                        rlAssertGrep "$value" tmp_attributes_selection
                    else
                        rlAssertNotGrep "$key" tmp_attributes.json
                    fi
                elif [[ $jq_element == parameters ]]; then
                    key="TMT_TREE"
                    rlAssertNotGrep "$key" tmp_attributes.json
                fi

                rm tmp_attributes*
            done

            rlLogInfo "Get all logs from the test $test_name"
            # REST API GET | log-controller (parent_id)
            response=$(rest_api GET "$URL/api/v1/$PROJECT/log/nested/$test_id")
            length=$(echo $response | jq -r ".content | length")
            level=("INFO" "ERROR")
            for ((content_index=0; content_index<$length; content_index++ )); do
                rlAssertEquals "Assert the level of the info log is correct" "$(echo $response | jq -r .content[$content_index].level)" "${level[$content_index]}"
                if [[ $i -ne 3 ]]; then
                    log_message=$(yq -r ".\"$test_name\".test" test.fmf | awk -F '"' '{print $2}' )
                    rlAssertEquals "Assert the message of the info log is correct" "$(echo $response | jq -r .content[$content_index].message)" "$log_message"
                fi
            done
        done

    rlPhaseEnd

    echo -e "\n\n\n::   PART 2\n"

    rlPhaseStartTest "Extended Functionality - LAUNCH-PER-PLAN"
        launch_name=${PLAN_PREFIX}/launch-per-plan

        rlRun -s "tmt run --verbose --all report --how reportportal --launch-per-plan --launch '$launch_name' " 2 "" 1>/dev/null
        foo_launch  # >> $launch_uuid, $launch_id
        rlAssertNotGrep "suite:" $rlRun_LOG
        foo_tests   # >> $test_uuid[1..3], $test_fullname[1..3]

        rlLogInfo "Get info about all launch items"
        # REST API GET | test-item-controller (launch_id)
        response=$(rest_api GET "$URL/api/v1/$PROJECT/item?filter.eq.launchId=$launch_id")

        length=$(echo $response | jq -r ".content | length")
        for ((content_index=0; content_index<$length; content_index++ )); do
            rlAssertEquals "Assert the item is no suite" "$(echo $response | jq -r .content[$content_index].hasChildren)" "false"
        done

    rlPhaseEnd


    rlPhaseStartTest "Extended Functionality - SUITE-PER-PLAN"
        launch_name=${PLAN_PREFIX}/suite-per-plan
        plan_summary=$(yq -r '.summary' plan.fmf)
        launch_description="Testing the integration of tmt and Report Portal via its API with suite-per-plan mapping"
        launch_status=$PLAN_STATUS
        suite_name=$PLAN_PREFIX
        rlRun -s "tmt run --verbose --all report --how reportportal --suite-per-plan --launch '$launch_name' --launch-description '$launch_description'" 2 "" 1>/dev/null
        foo_launch  # >> $launch_uuid, $launch_id
        foo_suite   # >> $suite_uuid, $suite_id
        foo_tests   # >> $test_uuid[1..3], $test_fullname[1..3]

        echo ""
        rlLogInfo "Get info about the launch"
        # REST API GET | launch-controller (uuid)
        response=$(rest_api GET "$URL/api/v1/$PROJECT/launch/uuid/$launch_uuid")
        rlAssertEquals "Assert the URL ID of launch is correct" "$(echo $response | jq -r '.id')" "$launch_id"
        rlAssertEquals "Assert the name of launch is correct" "$(echo $response | jq -r '.name')" "$launch_name"
        rlAssertEquals "Assert the status of launch is correct" "$(echo $response | jq -r '.status')" "$launch_status"
        rlAssertEquals "Assert the description of launch is correct" "$(echo $response | jq -r .description)" "$launch_description"

        # Check all the launch attributes
        rl_message="Test attributes of the launch (context)"
        echo "$response" | jq -r ".attributes" > tmp_attributes.json && rlPass "$rl_message" || rlFail "$rl_message"
        length=$(yq -r ".context | length" plan.fmf)
        for ((item_index=0; item_index<$length; item_index++ )); do
            echo ""
            key=$(yq -r ".context | keys | .[$item_index]" plan.fmf)
            value=$(yq -r ".context.$key" plan.fmf)
            rlAssertGrep "$key" tmp_attributes.json -A1 > tmp_attributes_selection
            rlAssertGrep "$value" tmp_attributes_selection
        done
        rm tmp_attributes*

        echo ""
        rlLogInfo "Get info about all launch items"
        # REST API GET | test-item-controller (launch_id)
        response=$(rest_api GET "$URL/api/v1/$PROJECT/item?filter.eq.launchId=$launch_id")
        length=$(echo $response | jq -r ".content | length")
        for ((content_index=0; content_index<$length; content_index++ )); do
            echo ""
            if [[ $content_index -eq 0 ]]; then
                rlAssertEquals "Assert the item is a suite" "$(echo $response | jq -r .content[$content_index].hasChildren)" "true"
                rlAssertEquals "Assert the name of suite item ${suite_name}" "$(echo $response | jq -r .content[$content_index].name)" "${suite_name}"
                rlAssertEquals "Assert the description of suite item ${suite_name}" "$(echo $response | jq -r .content[$content_index].description)" "$plan_summary"
            else
                i=$content_index
                rlAssertEquals "Assert the item is no suite" "$(echo $response | jq -r .content[$content_index].hasChildren)" "false"
                rlAssertEquals "Assert the name of test item ${test_name[$i]}" "$(echo $response | jq -r .content[$content_index].name)" "${test_fullname[$i]}"
                rlAssertEquals "Assert the uuid of test item ${test_name[$i]}" "$(echo $response | jq -r .content[$content_index].uuid)" "${test_uuid[$i]}"
            fi
        done

    rlPhaseEnd

     rlPhaseStartTest "Extended Functionality - HISTORY AGGREGATION"
        launch_name=${PLAN_PREFIX}/history-aggregation

        rlRun -s "tmt run --verbose --all report --how reportportal --suite-per-plan --launch '${launch_name}_1'" 2 "" 1>/dev/null

        for i in {1..3}; do
            echo ""
            test_fullname=${TEST_PREFIX}${test[$i,'name']}
            test_uuid=$(rlRun "grep -m$i -A1 'test:' $rlRun_LOG | tail -n1 | awk '{print \$NF}' ")
            rlAssertNotEquals "Assert the test$i uuid is not empty" "{$test_uuid}" ""

            rlLogInfo "Get info about the test item $i"
            # REST API GET | test-item-controller (uuid)
            response=$(rest_api GET "$URL/api/v1/$PROJECT/item/uuid/$test_uuid")
            rlAssertEquals "Assert the name is correct" "$(echo $response | jq -r '.name')" "$test_fullname"
            launch1_test_id[$i]=$(echo $response | jq -r '.id')
            rlAssertNotEquals "Assert the test id is not empty" "$launch1_test_id[$i]" ""
        done

        echo ""
        rlRun -s "tmt run --verbose --all report --how reportportal --suite-per-plan --launch '${launch_name}_2'" 2 "" 1>/dev/null

        for i in {1..3}; do
            echo ""
            test_name=${test[$i,'name']}
            test_fullname=${TEST_PREFIX}${test_name}
            test_uuid=$(rlRun "grep -m$i -A1 'test:' $rlRun_LOG | tail -n1 | awk '{print \$NF}' ")
            rlAssertNotEquals "Assert the test$i uuid is not empty" "{$test_uuid}" ""

            rlLogInfo "Get info about the test item $i"
            # REST API GET | test-item-controller (uuid)
            response=$(rest_api GET "$URL/api/v1/$PROJECT/item/uuid/$test_uuid")
            rlAssertEquals "Assert the name is correct" "$(echo $response | jq -r '.name')" "$test_fullname"
            launch2_test_id[$i]=$(echo $response | jq -r '.id')
            rlAssertNotEquals "Assert the test id is not empty" "$launch2_test_id[$i]" ""

            rlLogInfo "Verify the history is aggregated"
            # REST API GET | test-item-controller (history)
            response=$(rest_api GET "$URL/api/v1/$PROJECT/item/history?filter.eq.id=${launch2_test_id[$i]}&historyDepth=2")
            rlAssertEquals "Assert the previous item in history" "$(echo $response | jq -r .content[0].resources[1].id)" "${launch1_test_id[$i]}"
        done


        echo ""
        rlRun -s "tmt run --verbose --all report --how reportportal --suite-per-plan --launch '${launch_name}_3' --exclude-variables ''" 2 "" 1>/dev/null

        for i in {1..3}; do
            echo ""
            test_name=${test[$i,'name']}
            test_fullname=${TEST_PREFIX}${test_name}
            test_uuid=$(rlRun "grep -m$i -A1 'test:' $rlRun_LOG | tail -n1 | awk '{print \$NF}' ")
            rlAssertNotEquals "Assert the test$i uuid is not empty" "{$test_uuid}" ""

            # REST API GET | test-item-controller (uuid)
            response=$(rest_api GET "$URL/api/v1/$PROJECT/item/uuid/$test_uuid")
            rlAssertEquals "Assert the name is correct" "$(echo $response | jq -r '.name')" "$test_fullname"
            launch3_test_id[$i]=$(echo $response | jq -r '.id')
            rlAssertNotEquals "Assert the test id is not empty" "$launch3_test_id[$i]" ""
            test_case_id=$(yq -r ".\"$test_name\".id" test.fmf)
            [[ $test_case_id != null ]] && rlAssertEquals "Assert the test ${test_name} has a correct testCaseId" "$(echo $response | jq -r '.testCaseId')" "$test_case_id"
            echo "$response" | jq -r ".$jq_element" > tmp_attributes.json || rlFail "$jq_element listing into tmp_attributes.json"
            rlAssertGrep "TMT_TREE" tmp_attributes.json
            rm tmp_attributes*

            # history is not aggregated unless test case id is defined for given test (only test_2)
            [[ $i -eq 2 ]] && rlLogInfo "Verify the history is aggregated" || rlLogInfo "Verify the history is not aggregated"
            # REST API GET | test-item-controller (history)
            response=$(rest_api GET "$URL/api/v1/$PROJECT/item/history?filter.eq.id=${launch3_test_id[$i]}&historyDepth=2")
            [[ $i -eq 2 ]] && rlAssertEquals "Assert the previous item is in history" "$(echo $response | jq -r .content[0].resources[1].id)" "${launch2_test_id[$i]}" \
                           || rlAssertNotEquals "Assert the previous item is not in history" "$(echo $response | jq -r .content[0].resources[1].id)" "${launch2_test_id[$i]}"
        done

    rlPhaseEnd


    # Testing integration with ReportPortal build-in RERUN feature with Retry items
    rlPhaseStartTest "Extended Functionality - NAME-BASED RERUN"
        launch_name=${PLAN_PREFIX}/name-based-rerun
        suite_name=$PLAN_PREFIX

        rlRun -s "tmt run --verbose --all report --how reportportal --suite-per-plan --launch '$launch_name'" 2 "" 1>/dev/null
        for i in {1..3}; do
            core_test_uuid[$i]=$(rlRun "grep -m$i -A1 'test:' $rlRun_LOG | tail -n1 | awk '{print \$NF}' ")
            rlAssertNotEquals "Assert the test$i uuid is not empty" "{$core_test_uuid[$i]}" ""
        done

        echo ""
        rlRun -s "tmt run --verbose --all report --how reportportal --suite-per-plan --launch '$launch_name' --launch-rerun" 2 "" 1>/dev/null
        foo_launch  # >> $launch_uuid, $launch_id
        foo_suite   # >> $suite_uuid, $suite_id
        foo_tests   # >> $test_uuid[1..3], $test_fullname[1..3]
        rlAssertGrep "suite: $suite_name" $rlRun_LOG

        rlLogInfo "Get info about the launch"
        # REST API GET | launch-controller (uuid)
        response=$(rest_api GET "$URL/api/v1/$PROJECT/launch/uuid/$launch_uuid")
        rlAssertEquals "Assert the launch is rerun" "$(echo $response | jq -r '.rerun')" "true"

        rlLogInfo "Get info about all launch items"
        # REST API GET | test-item-controller (launch_id)
        response=$(rest_api GET "$URL/api/v1/$PROJECT/item?filter.eq.launchId=$launch_id")

        length=$(echo $response | jq -r ".content | length")
        for ((content_index=1; content_index<$length; content_index++ )); do
            i=$content_index
            rlAssertEquals "Assert the test item has correct UUID" "$(echo $response | jq -r .content[$content_index].uuid)" "${test_uuid[$i]}"
            rlAssertEquals "Assert the test item retry item has a correct UUID" "$(echo $response | jq -r .content[$content_index].retries[0].uuid)" "${core_test_uuid[$i]}"
        done
    rlPhaseEnd


    # Testing integration with tmt-stored UUIDs appending new logs to the same item
    rlPhaseStartTest "Extended Functionality - UUID-BASED RERUN"
        launch_name=${PLAN_PREFIX}/UUID-based-rerun
        suite_name=$PLAN_PREFIX

        rlRun -s "tmt run --verbose --all report --how reportportal --suite-per-plan --launch '$launch_name'" 2 "" 1>/dev/null
        foo_tests   # >> $test_uuid[1..3], $test_fullname[1..3]
        echo ""
        rlRun -s "tmt run --verbose --last --all report --how reportportal --suite-per-plan --launch '$launch_name' --again" 2 "" 1>/dev/null
        foo_launch  # >> $launch_uuid, $launch_id

        rlLogInfo "Get info about all launch items"
        # REST API GET | test-item-controller (launch_id)
        response=$(rest_api GET "$URL/api/v1/$PROJECT/item?filter.eq.launchId=$launch_id")

        length=$(echo $response | jq -r ".content | length")
        for ((content_index=1; content_index<$length; content_index++ )); do
            i=$content_index
            rlAssertEquals "Assert the test item has correct UUID" "$(echo $response | jq -r .content[$content_index].uuid)" "${test_uuid[$i]}"
            test_id[$i]="$(echo $response | jq -r .content[$content_index].id)"
            rlAssertNotEquals "Assert the test$i id is not empty" "${test_id[$i]}" ""

            test_name=${test[$i,'name']}
            rlLogInfo "Get all logs from the test$i"
            # REST API GET | log-controller (parent_id)
            response_log=$(rest_api GET "$URL/api/v1/$PROJECT/log/nested/${test_id[$i]}")

            length_log=$(echo $response_log | jq -r ".content | length")
            if [[ $i -eq 2 ]]; then
                level=("INFO" "INFO")
            else
                level=("INFO" "ERROR" "INFO" "ERROR")
            fi
            for ((content_index=0; content_index<$length_log; content_index++ )); do
                rlAssertEquals "Assert the level of the info log is correct" "$(echo $response_log | jq -r .content[$content_index].level)" "${level[$content_index]}"
                if [[ $i -ne 3 ]]; then
                    log_message=$(yq -r ".\"$test_name\".test" test.fmf | awk -F '"' '{print $2}' )
                    rlAssertEquals "Assert the message of the info log is correct" "$(echo $response_log | jq -r .content[$content_index].message)" "$log_message"
                fi
            done
        done

    rlPhaseEnd

    # Uploading empty report with IDLE states and updating it within the same tmt run
    rlPhaseStartTest "Extended Functionality - IDLE REPORT"
        launch_name=${PLAN_PREFIX}/idle_report
        suite_name=$PLAN_PREFIX

        rlRun -s "tmt run discover report --verbose --how reportportal --suite-per-plan --launch '$launch_name' --defect-type 'idle'" 3  "" 1>/dev/null
        foo_launch  # >> $launch_uuid, $launch_id
        foo_tests   # >> $test_uuid[1..3], $test_fullname[1..3]

        rlLogInfo "Get info about all launch items"
        # REST API GET | test-item-controller (launch_id)
        response=$(rest_api GET "$URL/api/v1/$PROJECT/item?filter.eq.launchId=$launch_id")

        length=$(echo $response | jq -r ".content | length")
        for ((content_index=1; content_index<$length; content_index++ )); do
            rlAssertEquals "Assert the defect type was defined" "$(echo $response | jq -r .content[$content_index].statistics.defects.to_investigate.total)" "1"

        done

        echo ""
        rlRun -s "tmt run --last --all report --verbose --how reportportal --suite-per-plan --launch '$launch_name' --again" 2 "" 1>/dev/null
        foo_launch  # >> $launch_uuid, $launch_id

        rlLogInfo "Get info about all launch items"
        # REST API GET | test-item-controller (launch_id)
        response=$(rest_api GET "$URL/api/v1/$PROJECT/item?filter.eq.launchId=$launch_id")

        length=$(echo $response | jq -r ".content | length")
        for ((content_index=1; content_index<$length; content_index++ )); do
            i=$content_index
            rlAssertEquals "Assert the test item has correct UUID" "$(echo $response | jq -r .content[$content_index].uuid)" "${test_uuid[$i]}"
            test_id[$i]="$(echo $response | jq -r .content[$content_index].id)"
            rlAssertNotEquals "Assert the test$i id is not empty" "${test_id[$i]}" ""

        done

    rlPhaseEnd

    # Uploading new suites and new tests to an existing launch
    rlPhaseStartTest "Extended Functionality - UPLOAD TO LAUNCH"
        launch_name=${PLAN_PREFIX}/upload-to-launch
        suite_name=$PLAN_PREFIX

        rlRun -s "tmt run --all report --verbose --how reportportal --suite-per-plan --launch '$launch_name'" 2 "" 1>/dev/null
        foo_launch  # >> $launch_uuid, $launch_id
        init_launch_uuid=$launch_uuid

        rlLogInfo "Get info about all launch items (1)"
        # REST API GET | test-item-controller (launch_id)
        response=$(rest_api GET "$URL/api/v1/$PROJECT/item?filter.eq.launchId=$launch_id")
        rlAssertEquals "Assert launch contains suite and 3 test items" "$(echo $response | jq -r .page.totalElements)" "4"

        echo ""
        rlRun -s "tmt run --all report --verbose --how reportportal --suite-per-plan --upload-to-launch '$launch_id'" 2 "" 1>/dev/null
        foo_launch  # >> $launch_uuid, $launch_id
        rlAssertEquals "Assert the launch uuid is same" "$init_launch_uuid" "$launch_uuid"

        rlLogInfo "Get info about all launch items (2)"
        # REST API GET | test-item-controller (launch_id)
        response=$(rest_api GET "$URL/api/v1/$PROJECT/item?filter.eq.launchId=$launch_id")
        rlAssertEquals "Assert launch contains another suite and 3 test items" "$(echo $response | jq -r .page.totalElements)" "8"

        echo ""
        rlRun -s "tmt run --all report --verbose --how reportportal --launch-per-plan --upload-to-launch '$launch_id'" 2 "" 1>/dev/null
        foo_launch  # >> $launch_uuid, $launch_id
        rlAssertEquals "Assert the launch uuid is same" "$init_launch_uuid" "$launch_uuid"

        rlLogInfo "Get info about all launch items (3)"
        # REST API GET | test-item-controller (launch_id)
        response=$(rest_api GET "$URL/api/v1/$PROJECT/item?filter.eq.launchId=$launch_id")
        rlAssertEquals "Assert launch contains another 3 test items" "$(echo $response | jq -r .page.totalElements)" "11"

    rlPhaseEnd


    # Uploading new suites and new tests to an existing suite
    rlPhaseStartTest "Extended Functionality - UPLOAD TO SUITE"
        launch_name=${PLAN_PREFIX}/upload-to-suite
        suite_name=$PLAN_PREFIX

        rlRun -s "tmt run --all report --verbose --how reportportal --suite-per-plan --launch '$launch_name'" 2 ""
        #TODO get suite uuid
        foo_launch  # >> $launch_uuid, $launch_id
        foo_suite  # >> $suite_uuid
        init_launch_uuid=$launch_uuid

        # response=$(rest_api GET "$URL/api/v1/$PROJECT/item/$suite_uuid")

        # echo $response | jq
        # suite_id=$(echo $response | jq -r .id)
        # echo $suite_id

        # #TODO verify new tests created in given suite
        # rlLogInfo "Get info about all launch items (1)"
        # # REST API GET | test-item-controller (parent_id)
        # response=$(rest_api GET "$URL/api/v1/$PROJECT/item?filter.eq.launchId=$launch_id&filter.eq.parentId=$suite_id")

        # echo $response | jq

        # rlAssertEquals "Assert launch contains suite and 3 test items" "$(echo $response | jq -r .page.totalElements)" "3"

        # echo ""

        # rlRun -s "tmt run --all report --verbose --how reportportal --upload-to-suite '$suite_id'" 2 "" 1>/dev/null

    rlPhaseEnd


    rlPhaseStartCleanup
        rlRun "rm -rf $run" 0 "Remove run workdir"
        rlRun "popd"
    rlPhaseEnd
rlJournalEnd
