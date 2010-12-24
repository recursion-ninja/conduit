{-# LANGUAGE OverloadedStrings #-}
import Test.Framework (defaultMain, testGroup, Test)
import Test.Framework.Providers.HUnit
import Test.HUnit hiding (Test)

import Network.Wai
import Network.Wai.Parse
import qualified Data.ByteString as S
import qualified Data.ByteString.Char8 as S8
import qualified Data.ByteString.Lazy.Char8 as L8
import Control.Arrow

import Data.Enumerator (run_, enumList, ($$))
import Control.Monad.IO.Class (liftIO)

main :: IO ()
main = defaultMain [testSuite]

testSuite :: Test
testSuite = testGroup "Network.Wai.Parse"
    [ testCase "parseQueryString" caseParseQueryString
    , testCase "parseQueryString with question mark" caseParseQueryStringQM
    , testCase "parseHttpAccept" caseParseHttpAccept
    , testCase "parseRequestBody" caseParseRequestBody
    , testCase "findBound" caseFindBound
    , testCase "sinkTillBound" caseSinkTillBound
    , testCase "killCR" caseKillCR
    , testCase "killCRLF" caseKillCRLF
    , testCase "takeLine" caseTakeLine
    ]

caseParseQueryString :: Assertion
caseParseQueryString = do
    let go l r =
            map (S8.pack *** S8.pack) l @=? parseQueryString (S8.pack r)

    go [] ""
    go [("foo", "")] "foo"
    go [("foo", "bar")] "foo=bar"
    go [("foo", "bar"), ("baz", "bin")] "foo=bar&baz=bin"
    go [("%Q", "")] "%Q"
    go [("%1Q", "")] "%1Q"
    go [("%1", "")] "%1"
    go [("/", "")] "%2F"
    go [("/", "")] "%2f"
    go [("foo bar", "")] "foo+bar"

caseParseQueryStringQM :: Assertion
caseParseQueryStringQM = do
    let go l r =
            map (S8.pack *** S8.pack) l
                @=? parseQueryString (S8.pack $ '?' : r)

    go [] ""
    go [("foo", "")] "foo"
    go [("foo", "bar")] "foo=bar"
    go [("foo", "bar"), ("baz", "bin")] "foo=bar&baz=bin"
    go [("%Q", "")] "%Q"
    go [("%1Q", "")] "%1Q"
    go [("%1", "")] "%1"
    go [("/", "")] "%2F"
    go [("/", "")] "%2f"
    go [("foo bar", "")] "foo+bar"

caseParseHttpAccept :: Assertion
caseParseHttpAccept = do
    let input =
          S8.pack "text/plain; q=0.5, text/html, text/x-dvi; q=0.8, text/x-c"
        expected = ["text/html", "text/x-c", "text/x-dvi", "text/plain"]
    map S8.pack expected @=? parseHttpAccept input

caseParseRequestBody :: Assertion
caseParseRequestBody = run_ t where
    content2 = S8.pack $
        "--AaB03x\n" ++
        "Content-Disposition: form-data; name=\"document\"; filename=\"b.txt\"\n" ++
        "Content-Type: text/plain; charset=iso-8859-1\n\n" ++
        "This is a file.\n" ++
        "It has two lines.\n" ++
        "--AaB03x\n" ++
        "Content-Disposition: form-data; name=\"title\"\n" ++
        "Content-Type: text/plain; charset=iso-8859-1\n\n" ++
        "A File\n" ++
        "--AaB03x\n" ++
        "Content-Disposition: form-data; name=\"summary\"\n" ++
        "Content-Type: text/plain; charset=iso-8859-1\n\n" ++
        "This is my file\n" ++
        "file test\n" ++
        "--AaB03x--"
    content3 = S8.pack "------WebKitFormBoundaryB1pWXPZ6lNr8RiLh\r\nContent-Disposition: form-data; name=\"yaml\"; filename=\"README\"\r\nContent-Type: application/octet-stream\r\n\r\nPhoto blog using Hack.\n\r\n------WebKitFormBoundaryB1pWXPZ6lNr8RiLh--\r\n"
    t = do
        let content1 = S8.pack "foo=bar&baz=bin"
        let ctype1 = S8.pack "application/x-www-form-urlencoded"
        result1 <- parseRequestBody lbsSink $ toRequest ctype1 content1
        liftIO $ assertEqual "parsing post x-www-form-urlencoded"
                    (map (S8.pack *** S8.pack) [("foo", "bar"), ("baz", "bin")], [])
                    result1

        let ctype2 = S8.pack "multipart/form-data; boundary=AaB03x"
        result2 <- parseRequestBody lbsSink $ toRequest ctype2 content2
        let expectedsmap2 =
              [ ("title", "A File")
              , ("summary", "This is my file\nfile test")
              ]
        let textPlain = S8.pack $ "text/plain; charset=iso-8859-1"
        let expectedfile2 =
              [(S8.pack "document", FileInfo (S8.pack "b.txt") textPlain $ L8.pack
                 "This is a file.\nIt has two lines.")]
        let expected2 = (map (S8.pack *** S8.pack) expectedsmap2, expectedfile2)
        liftIO $ assertEqual "parsing post multipart/form-data"
                    expected2
                    result2

        let ctype3 = S8.pack "multipart/form-data; boundary=----WebKitFormBoundaryB1pWXPZ6lNr8RiLh"
        result3 <- parseRequestBody lbsSink $ toRequest ctype3 content3
        let expectedsmap3 = []
        let expectedfile3 = [(S8.pack "yaml", FileInfo (S8.pack "README") (S8.pack "application/octet-stream") $
                                L8.pack "Photo blog using Hack.\n")]
        let expected3 = (expectedsmap3, expectedfile3)
        liftIO $ assertEqual "parsing actual post multipart/form-data"
                    expected3
                    result3

        result2' <- parseRequestBody lbsSink $ toRequest' ctype2 content2
        liftIO $ assertEqual "parsing post multipart/form-data 2"
                    expected2
                    result2'

        result3' <- parseRequestBody lbsSink $ toRequest' ctype3 content3
        liftIO $ assertEqual "parsing actual post multipart/form-data 2"
                    expected3
                    result3'

toRequest :: S8.ByteString -> S8.ByteString -> Request
toRequest ctype content = Request
    { requestHeaders = [("Content-Type", ctype)]
    , requestBody = enumList 1 [content]
    }

toRequest' :: S8.ByteString -> S8.ByteString -> Request
toRequest' ctype content = Request
    { requestHeaders = [("Content-Type", ctype)]
    , requestBody = enumList 1 $ map S.singleton $ S.unpack content
    }

caseFindBound :: Assertion
caseFindBound = do
    findBound (S8.pack "def") (S8.pack "abcdefghi") @?=
        FoundBound (S8.pack "abc") (S8.pack "ghi")
    findBound (S8.pack "def") (S8.pack "ABC") @?= NoBound
    findBound (S8.pack "def") (S8.pack "abcd") @?= PartialBound
    findBound (S8.pack "def") (S8.pack "abcdE") @?= NoBound
    findBound (S8.pack "def") (S8.pack "abcdEdef") @?=
        FoundBound (S8.pack "abcdE") (S8.pack "")

caseSinkTillBound :: Assertion
caseSinkTillBound = do
    let iter () _ = return ()
    let src = S8.pack "this is some text"
        bound1 = S8.pack "some"
        bound2 = S8.pack "some!"
    let enum = enumList 1 [src]
    let helper _ _ = return ()
    (_, res1) <- run_ $ enum $$ sinkTillBound bound1 helper ()
    res1 @?= True
    (_, res2) <- run_ $ enum $$ sinkTillBound bound2 helper ()
    res2 @?= False

caseKillCR :: Assertion
caseKillCR = do
    "foo" @=? killCR "foo"
    "foo" @=? killCR "foo\r"
    "foo\r\n" @=? killCR "foo\r\n"
    "foo\r'" @=? killCR "foo\r'"

caseKillCRLF :: Assertion
caseKillCRLF = do
    "foo" @=? killCRLF "foo"
    "foo\r" @=? killCRLF "foo\r"
    "foo" @=? killCRLF "foo\r\n"
    "foo\r'" @=? killCRLF "foo\r'"
    "foo" @=? killCRLF "foo\n"

caseTakeLine :: Assertion
caseTakeLine = do
    helper "foo\nbar\nbaz" "foo"
    helper "foo\r\nbar\nbaz" "foo"
    helper "foo\nbar\r\nbaz" "foo"
    helper "foo\rbar\r\nbaz" "foo\rbar"
  where
    helper haystack needle = do
        x <- run_ $ enumList 1 [haystack] $$ takeLine
        Just needle @=? x
